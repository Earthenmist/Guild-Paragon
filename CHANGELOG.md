# 1.6.0-Release

## Changes
- Guild Sync now checks for differences on login or reload, transfers the records needed, and sends live updates afterwards. Interrupted syncs retain progress and resume when peers are available. Existing permissions and combat restrictions remain.
- Compressed sync traffic reduces data transfers. Large records use acknowledged segments with retry recovery. Updated status text explains category checks, received updates and deferred peers.
- Added Guild Invite beside recruitment cooldown entries in Ban List. Select an Antispam entry to send one manual invite without retyping the name; its cooldown remains active.
- Added an optional General setting to open Guild Paragon with the guild shortcut. Disabled by default; reload after changing it. Unavailable during combat.

## Fixes
- Compacted the General Settings keybinding row to keep the lower panel inside the window.
- Completed English string coverage for the updated Guild Sync screen.

## Known issues
- All participants should update to 1.6.0 for the new sync system. Event Log replacement remains manual.
