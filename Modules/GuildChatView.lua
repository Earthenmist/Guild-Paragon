-- Visible-only Club chat access. Message content is display-only, never persisted.
local _, GP = ...
local Chat = {}
GP.GuildChatView = Chat
local function value(v, kind)
    if not GP:IsSecretValue(v) and type(v) == kind then return v end
end
local function read(fn, kind, ...)
    if type(fn) ~= "function" then return nil end
    local ok, v = pcall(fn, ...)
    if ok then return value(v, kind) end
end
local function identifier(v)
    v = value(v, "table")
    if v and value(v.epoch, "number") and value(v.position, "number") then
        return {epoch=v.epoch, position=v.position}
    end
end
local function discordMetadata(author)
    local source=author and value(author.discordInfo,"table")
    if not source or value(source.fromDiscord,"boolean")~=true then return nil end
    local info={fromDiscord=true}
    for _,key in ipairs({"globalName","lastOnlineName","lastOnlineGUID","forwardedMessage"}) do
        info[key]=value(source[key],"string")
    end
    info.type=value(source.type,"number")
    for _,key in ipairs({"hasAttachment","hasPoll","hasEmbed","hasSticker","hasEmoji","hasForwardedMessage","hasError"}) do
        info[key]=value(source[key],"boolean")==true
    end
    if not info.forwardedMessage then info.hasForwardedMessage=false end
    return info
end
function Chat:OpenWhisper(club,stream,kind,record)
    if not self:Allowed(club,stream,kind) or not record or not value(record.whisperName,"string") then return false end
    local sendTell=ChatFrameUtil and ChatFrameUtil.SendTell or ChatFrame_SendTell
    if type(sendTell)~="function" then return false end
    -- This opens an empty composer. It never sends a message.
    return pcall(sendTell,record.whisperName)
end
function Chat:PrivacyEnabled()
    local settings=value(EllesmereUIDB,"table")
    return settings and value(settings.guildChatPrivacy,"boolean") == true or false
end
function Chat:IsSafe()
    local context = GP:GetModule("GuildApplicants", true)
    return context and context:IsSafe() and read(IsInGuild, "boolean") == true
end
function Chat:Channels()
    if not self:IsSafe() or not C_Club or not Enum or not Enum.ClubStreamType then return nil, {} end
    local club = read(C_Club.GetGuildClubId, "number")
    if not club then return nil, {} end
    local streams = read(C_Club.GetStreams, "table", club) or {}
    local channels = {}
    for i=1,math.min(#streams,50) do
        local stream = value(streams[i], "table")
        local kind = stream and value(stream.streamType, "number")
        local id = stream and value(stream.streamId, "number")
        if id and kind == Enum.ClubStreamType.Guild then channels.guild=id
        elseif id and kind == Enum.ClubStreamType.Officer then channels.officer=id end
    end
    return club, channels
end
function Chat:Allowed(club, stream, kind)
    local current, channels = self:Channels()
    return current ~= nil and current == club and channels[kind] ~= nil and channels[kind] == stream
end
function Chat:CanSend(club, stream, kind)
    if not self:Allowed(club, stream, kind) then return false end
    if read(C_Club.IsSubscribedToStream, "boolean", club, stream) ~= true then return false end
    if read(C_Club.IsAccountMuted, "boolean", club) ~= false then return false end
    if kind == "guild" and read(C_GuildInfo and C_GuildInfo.CanSpeakInGuildChat, "boolean") ~= true then return false end
    return type(C_Club.SendMessage) == "function"
end
function Chat:Send(club, stream, kind, message)
    if not value(message,"string") or #message == 0 or #message > 255 then return false end
    if not self:CanSend(club, stream, kind) then return false end
    -- Only called by the user's Send/Enter action; no retries or queued sends.
    return pcall(C_Club.SendMessage, club, stream, message)
end
function Chat:Request(club, stream, kind, cursor)
    if not self:Allowed(club, stream, kind) then return false end
    if type(C_Club.RequestMoreMessagesBefore) ~= "function" then return false end
    local ok, available = pcall(C_Club.RequestMoreMessagesBefore, club, stream, cursor, 100)
    return ok, ok and value(available,"boolean") == true
end
function Chat:Messages(club, stream, kind, cursor)
    if not self:Allowed(club, stream, kind) then return {}, nil, true end
    local newest = identifier(cursor)
    if not newest then
        local ranges = read(C_Club.GetMessageRanges,"table",club,stream)
        local range = ranges and value(ranges[#ranges],"table")
        newest = range and identifier(range.newestMessageId)
    end
    if not newest then return {}, nil, false end
    local messages = read(C_Club.GetMessagesBefore,"table",club,stream,newest,100) or {}
    local rows, oldest, records = {}, nil, {}
    for i=1,math.min(#messages,100) do
        local message = value(messages[i],"table")
        local id = message and identifier(message.messageId)
        if id then oldest = oldest or id end
        local author = message and value(message.author,"table")
        local name = author and value(author.name,"string")
        local discord=discordMetadata(author)
        local content = message and value(message.content,"string")
        if discord then
            local nativeName=read(ChatFrameUtil and ChatFrameUtil.GetNameForDiscordMessage,"string",discord)
            local globalType=Enum.DiscordDisplayNameType and Enum.DiscordDisplayNameType.GlobalName
            name=nativeName or (discord.type~=globalType and discord.lastOnlineName) or discord.globalName or name or GP.L["Discord user"]
            if not GP:IsSecretValue(message.content) and message.content==nil then content="" end
            if content then content=read(ChatFrameUtil and ChatFrameUtil.FormatDiscordMessage,"string",discord,content) or content end
        end
        local record = id and {id=id, key=id.epoch .. ":" .. id.position}
        if record then records[#records+1]=record end
        if record and name and content and value(message.destroyed,"boolean") == false then
            -- Preserve opaque |K tokens for Blizzard's renderer. Never search or decode.
            local prefix = ""
            local stamp = id and C_DateAndTime and read(C_DateAndTime.GetCalendarTimeFromEpoch,"table",id.epoch)
            if stamp and value(stamp.monthDay,"number") and value(stamp.month,"number")
                and value(stamp.hour,"number") and value(stamp.minute,"number") then
                prefix = string.format("[%02d:%02d] ",stamp.hour,stamp.minute)
                record.day = string.format("%02d/%02d",stamp.monthDay,stamp.month)
                local year=value(stamp.year,"number")
                if year then
                    record.day=GP:DisplayDate(GP.L["Chat date format"],time({year=year,month=stamp.month,day=stamp.monthDay,hour=12}))
                end
            end
            local classID = value(author.classID,"number")
            local class = classID and C_CreatureInfo and read(C_CreatureInfo.GetClassInfo,"table",classID)
            local token = class and value(class.classFile,"string")
            local color = token and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
            local code = color and value(color.colorStr,"string")
            local displayName = not discord and code and ("|c" .. code .. name .. "|r") or name
            if discord then
                local icon=read(CreateAtlasMarkup,"string","UI-ChatIcon-Discord") or GP.L["[Discord]"]
                prefix=icon.." "..prefix
            end
            record.text = prefix .. displayName .. ": " .. content
            local clubType=value(author.clubType,"number")
            if not discord and not GP:IsSecretValue(author.discordInfo) and author.discordInfo==nil
                and not GP:IsSecretValue(author.clubType) and (not clubType or not Enum.ClubType or clubType~=Enum.ClubType.BattleNet) then
                record.whisperName=name
                record.link="gpchatplayer:"..record.key
                record.linkedText=prefix.."|H"..record.link.."|h"..displayName.."|h: "..content
            end
            rows[#rows+1] = record.text
        end
    end
    local beginning = oldest and read(C_Club.IsBeginningOfStream,"boolean",club,stream,oldest) == true
    return rows, oldest, beginning, records
end

-- A bounded display window; discard the opposite end when browsing farther back.
function Chat:Merge(existing, incoming, browsingOlder)
    local byID = {}
    for _,record in ipairs(existing) do byID[record.key]=record end
    for _,record in ipairs(incoming) do byID[record.key]=record end
    local merged={}
    for _,record in pairs(byID) do merged[#merged+1]=record end
    table.sort(merged,function(a,b)
        return a.id.epoch<b.id.epoch or (a.id.epoch==b.id.epoch and a.id.position<b.id.position)
    end)
    local result={}
    local first=browsingOlder and 1 or math.max(1,#merged-499)
    for i=first,math.min(#merged,first+499) do result[#result+1]=merged[i] end
    return result
end

function Chat:Lines(records)
    local lines, day = {}, nil
    for _,record in ipairs(records) do
        if record.text then
            if record.day and record.day~=day then
                day=record.day
                lines[#lines+1]={key="day-before:"..record.key,text=" "}
                lines[#lines+1]={key="day:"..record.key,text=day,heading=true}
                lines[#lines+1]={key="day-after:"..record.key,text=" "}
            end
            lines[#lines+1]={key=record.key,text=record.linkedText or record.text}
        end
    end
    return lines
end
