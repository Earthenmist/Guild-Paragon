# Guild Paragon Public API

Guild Paragon exposes a small read-only API for other addons that want to
display, search, summarize, or react to supported Guild Paragon data without
depending on internal SavedVariables or module tables.

```lua
local API = _G.GuildParagonAPI
```

## API Status

The v1 API is read-only and versioned.

```lua
GuildParagonAPI.GetAPIVersion()     -- 1
GuildParagonAPI.GetAddonVersion()   -- loaded Guild Paragon addon version
GuildParagonAPI.IsReady()           -- true once current-guild roster data exists
```

Only functions documented in this file are public. SavedVariables,
`GP:GetModule(...)`, module-local data, UI frames, and undocumented functions are
private implementation details and may change between Guild Paragon releases.

## Read-Only by Design

Guild Paragon's public API is read-only in v1.

v1 does not expose write/edit methods such as:

- setting nicknames
- setting custom notes
- setting officer notes
- changing alt/main links
- editing birthdays or join dates
- editing Ban List or Do Not Invite records
- starting scans, syncs, recruitment actions, invites, whispers, or macros

This is deliberate. Guild Paragon write paths include permission checks,
officer-only data boundaries, sync conflict handling, event logging,
Midnight/protected-content safety checks, and user-facing confirmation flows.
Exposing write APIs before those contracts are fully designed would make it too
easy for another addon to bypass Guild Paragon's safety model.

Future write APIs may be considered only for narrow, well-tested use cases. If
added, they will be documented separately, versioned, and routed through the
same permission, safety, sync, and logging paths used by Guild Paragon itself.

## Data Safety

- Returned tables are new tables intended for reading.
- Do not hold returned tables forever; request fresh data after update callbacks.
- Officer-only values return `nil` unless the local player can access officer
  data.
- API calls use already-stored Guild Paragon data. They do not trigger roster
  scans, sync requests, recruitment actions, invites, whispers, macros, or fresh
  Blizzard data lookups.

## Member Shape

Member functions return a table like:

```lua
{
    guid = "Player-...",
    name = "Lanni-Alonsus",
    shortName = "Lanni",
    realm = "Alonsus",
    class = "PRIEST",
    rankName = "Guild Master",
    rankIndex = 0,
    level = 90,
    online = true,
    onlineSince = 1234567890,
    lastOnline = 0,
    lastSeen = 1234567890,
    firstSeen = 1234567890,
    former = false,
    leftDate = nil,
    note = "Holy - 293",
    nickname = "Lanni",
    customNote = "Joined: 2010-11-01",
    mainGUID = nil,
    altGUIDs = { "Player-..." },
    isMain = true,
    isMarkedMain = true,
    birthday = { day = 17, month = 7 },
    joinDate = "2010-11-01",
    joinDateSource = "custom",

    -- Officer-only when available:
    officerNote = "",
    customOfficerNote = "",
}
```

## Functions

```lua
GuildParagonAPI.GetCurrentGuild()
```

Returns `{ key, name, active, former, lastScan }`, or `nil` if no current Guild
Paragon guild data is available.

```lua
GuildParagonAPI.GetRoster(includeFormer)
```

Returns an alphabetically sorted array of member tables. Former members are
included only when `includeFormer` is true.

```lua
GuildParagonAPI.GetMember(nameOrGUID, includeFormer)
```

Returns one member table by GUID, full name, or unambiguous short name. Former
members are searched only when `includeFormer` is true.

```lua
GuildParagonAPI.IsGuildMember(nameOrGUID)
```

Returns true only for current active roster members.

```lua
GuildParagonAPI.GetMain(nameOrGUID)
GuildParagonAPI.GetAlts(nameOrGUID)
```

Returns the tagged main member, or an array of tagged alt members.

```lua
GuildParagonAPI.GetNickname(nameOrGUID)
GuildParagonAPI.GetBirthday(nameOrGUID)
GuildParagonAPI.GetJoinDate(nameOrGUID)
GuildParagonAPI.GetCustomNote(nameOrGUID)
```

Convenience readers for common member fields.

```lua
GuildParagonAPI.CanAccessOfficerData()
GuildParagonAPI.GetOfficerNote(nameOrGUID)
GuildParagonAPI.GetCustomOfficerNote(nameOrGUID)
```

Officer readers return `nil` when the local player cannot access officer data.

```lua
GuildParagonAPI.GetRecentHistory(nameOrGUID, limit)
```

Returns up to `limit` recent displayable Event Log records for the member.
`limit` defaults to 10 and is capped at 50.

```lua
GuildParagonAPI.GetStats()
```

Returns `{ guildKey, guildName, active, former, online, logEntries, lastScan }`.

## Callbacks

The API uses CallbackHandler-1.0 style callbacks:

```lua
GuildParagonAPI.RegisterCallback(owner, "GuildParagonAPI_Ready", "OnReady")
GuildParagonAPI.RegisterCallback(owner, "GuildParagonAPI_RosterUpdated", "OnRoster")
GuildParagonAPI.RegisterCallback(owner, "GuildParagonAPI_MemberUpdated", "OnMember")
GuildParagonAPI.RegisterCallback(owner, "GuildParagonAPI_LogUpdated", "OnLog")
```

Callback payloads are intentionally lightweight and may mirror internal update
arguments. Treat them as "data changed" notifications, then call the read API for
fresh data.

## Examples

```lua
local API = _G.GuildParagonAPI
if API and API.IsReady() then
    local member = API.GetMember("Lanni-Alonsus", true)
    if member then
        print(member.name, member.nickname or "")
    end
end
```

```lua
local API = _G.GuildParagonAPI
local alts = API and API.GetAlts("Lanni-Alonsus")
for _, alt in ipairs(alts or {}) do
    print(alt.name, alt.class or "")
end
```
