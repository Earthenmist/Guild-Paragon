-- Midnight-safe value helpers for Blizzard API results.
local _, GP = ...

function GP:IsSecretValue(value)
    return issecretvalue and issecretvalue(value) and true or false
end

function GP:CanAccessValue(value)
    if not self:IsSecretValue(value) then return true end
    if not canaccessvalue then return false end

    local ok, accessible = pcall(canaccessvalue, value)
    return ok and accessible and true or false
end

function GP:SafeValue(value, fallback)
    if self:IsSecretValue(value) and not self:CanAccessValue(value) then
        return fallback
    end
    return value
end

function GP:SafeString(value, fallback)
    value = self:SafeValue(value, nil)
    if type(value) == "string" then return value end
    if type(value) == "number" or type(value) == "boolean" then return tostring(value) end
    return fallback or ""
end

function GP:SafeOptionalString(value)
    value = self:SafeValue(value, nil)
    if type(value) == "string" then return value end
    if type(value) == "number" or type(value) == "boolean" then return tostring(value) end
    return nil
end

function GP:SafeNumber(value, fallback)
    value = self:SafeValue(value, nil)
    if type(value) == "number" then return value end
    if type(value) == "string" then return tonumber(value) or fallback end
    return fallback
end

function GP:SafeBool(value, fallback)
    value = self:SafeValue(value, nil)
    if type(value) == "boolean" then return value end
    return fallback and true or false
end

function GP:SafeCall(fn, fallback, ...)
    if type(fn) ~= "function" then return fallback end

    local ok, result = pcall(fn, ...)
    if not ok then return fallback end
    return self:SafeValue(result, fallback)
end

function GP:LocalPlayerFullName()
    local name = UnitName and UnitName("player")
    if not name or name == "" then return nil end
    local realm = GetNormalizedRealmName and GetNormalizedRealmName()
    if not realm or realm == "" then return name end
    return name .. "-" .. realm
end
