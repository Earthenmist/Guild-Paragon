# Changelog

## 2026-09-25 - v1.5.0-Release

### Changes

- Retail main-profession browser: member search, offline members shown by default, an optional online-only filter and native recipe viewing.
- Initial WoW Forever beta support in the same package as Retail, with older guild APIs and class colours supported.
- Both clients: roster Recent History and Audit Details now open in flyouts beside Macro Rules. All four notes share a compact column, with editable custom notes and read-only Blizzard notes respecting officer permissions.
- Forever Guild Health replaces M+ information with Upcoming Birthdays and Level Distribution. Upcoming Dates has a wider button on both clients.
- Added `/gp client` for client compatibility diagnostics.

### Fixes

- Forever hides unsupported Housing, M+, Achievement Points, Achievement chat, Guild Challenges, Guild Finder and Applications features, and skips Housing requests.
- Forever recruitment suppresses scan-triggered Who popups, uses click-driven queries, its nine classes and ten races (including both Skyborne variants), and separate invalid-zone defaults without Retail-only content.
- Forever guild invites, recruitment and Guild Sync preserve full character names without adding a realm suffix. Retail retains Name-Realm support.
- Fixed startup when no other addon supplies AceComm by loading the bundled library.
- Existing Retail behavior and saved preferences are preserved unless a shared change is listed above.

### Known issues

- Forever client compatibility remains subject to beta changes. Additional beta instance names may require custom invalid-zone entries. Companion support remains Retail-only.
