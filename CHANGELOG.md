# Changelog

## 2026-08-21 - v1.1.0-Release

### Changes

- Added Guild Health, a new officer dashboard with Overview, Attention, Recruitment, and Exports views for spotting roster risks, new-member promotion reviews, M+ coverage, recruitment activity, and follow-up actions from one place.
- Added configurable Health rules for activity windows, linked-character handling, Mythic+ season start, new-member follow-up, promotion review, and Macro Rule ignore visibility.
- Added Guild Health actions to open members in Roster, manage Macro Rules, and prepare promotion macros through the existing Macro Tool keybind workflow.
- Moved Backup & Restore into Settings, moved Exports under Guild Health, and reordered navigation so Roster and Guild Health are the primary dashboard entries.
- Added assigned-player visibility to Settings > Labels, with click-through to open the selected player in the Roster.

### Fixes

- Hardened Recruitment right-click handling around protected Blizzard roster/menu data to prevent taint errors.
- Added two-scan confirmation before logging roster departures, preventing brief Blizzard roster-cache gaps from creating false leave/rejoin Event Log pairs.
- Fixed a missing Settings > Health label for Macro Rule Ignores.
- Improved hidden-tab and Guild Health refresh performance during bursty roster, sync, recruitment, and log updates.
- Split more Guild Sync work across frames to reduce short freezes during large sync updates and full-state preparation.

### Known issues
- None known.
