-- Guild Paragon — localized chat-pattern helpers
--
-- Helpers for matching Blizzard's localized system-message strings without
-- hardcoded English text.
local _, GP = ...

local PLACEHOLDER_TOKEN = "\001"

function GP:StripChatLinkMarkup(message)
    if type(message) ~= "string" then return message end
    return (message:gsub("|H[^|]*|h", ""):gsub("|h", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

-- Builds an anchored Lua pattern from a localized Blizzard format string.
function GP:BuildChatPattern(formatString)
    if type(formatString) ~= "string" or formatString == "" then return nil end
    local value = self:StripChatLinkMarkup(formatString)
    value = value:gsub("%%s", PLACEHOLDER_TOKEN):gsub("%%d", PLACEHOLDER_TOKEN)
    value = value:gsub("([%^%$%(%)%%%.%*%+%-%?%[%]])", "%%%1")
    value = value:gsub(PLACEHOLDER_TOKEN, "(.-)")
    return "^" .. value .. "$"
end

-- Longest literal segment used for a cheap pre-match string.find.
function GP:BuildChatNeedle(formatString)
    if type(formatString) ~= "string" or formatString == "" then return nil end
    local value = self:StripChatLinkMarkup(formatString)
    value = value:gsub("%%s", PLACEHOLDER_TOKEN):gsub("%%d", PLACEHOLDER_TOKEN)
    local longest = ""
    for fragment in (value .. PLACEHOLDER_TOKEN):gmatch("(.-)" .. PLACEHOLDER_TOKEN) do
        if #fragment > #longest then longest = fragment end
    end
    longest = longest:gsub("^%s+", ""):gsub("%s+$", "")
    if longest == "" then return nil end
    return longest
end
