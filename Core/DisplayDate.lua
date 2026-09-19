local _, GP = ...
local formats = { ["DD-MM-YYYY"] = "%d-%m-%Y", ["MM-DD-YYYY"] = "%m-%d-%Y" }
function GP:DisplayDate(originalFormat, timestamp)
    if self:IsSecretValue(timestamp) or type(timestamp) ~= "number" then return "" end
    local ui = self.db and self.db.profile and self.db.profile.ui
    local selected = ui and formats[ui.dateFormat]
    local format = originalFormat
    if selected then
        local clock = originalFormat:find("%%H")
        format = selected .. (clock and (" " .. originalFormat:sub(clock)) or "")
    end
    return date(format, timestamp)
end

function GP:DisplayEventDate(entry)
    if entry.type ~= "joindate" or self:IsSecretValue(entry.date) or type(entry.date) ~= "string" then return entry end
    local y, m, d = entry.date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    local ui = self.db and self.db.profile and self.db.profile.ui
    local mode = ui and ui.dateFormat
    if not y or not formats[mode] then return entry end
    local copy = {}
    for key, value in pairs(entry) do copy[key] = value end
    copy.date = mode == "DD-MM-YYYY" and (d .. "-" .. m .. "-" .. y) or (m .. "-" .. d .. "-" .. y)
    return copy
end

function GP:JoinDateInputFormat()
    local ui = self.db and self.db.profile and self.db.profile.ui
    local mode = ui and ui.dateFormat
    return formats[mode] and mode or "YYYY-MM-DD"
end

function GP:CanonicalJoinDateInput(text)
    if self:IsSecretValue(text) or type(text) ~= "string" then return nil end
    local mode = self:JoinDateInputFormat()
    if mode == "YYYY-MM-DD" then return text end
    local a, b, year = text:match("^%s*(%d%d?)%-(%d%d?)%-(%d%d%d%d)%s*$")
    if not year then return nil end
    local month, day = tonumber(b), tonumber(a)
    if mode == "MM-DD-YYYY" then month, day = day, month end
    return string.format("%s-%02d-%02d", year, month, day)
end
