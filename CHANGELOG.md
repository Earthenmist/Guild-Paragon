# Changelog

## 2026-09-09 - v1.3.0-Release

### Changes

- Full-state and safety catch-up syncs accept up to three updated peers at
  once; additional peers retry after ten minutes. Live updates continue normally.
- Macro Tool shortcuts now use Blizzard Keybindings under Guild Paragon.
- Close buttons have a larger target and a clearer ×.
- Added support files and integration for Guild Paragon Companion, an optional
  feature. More details will be posted to Discord soon.

### Fixes

- Minimap collectors can manage the LibDBIcon launcher; saved position and
  visibility are retained. Clearing a Macro Tool shortcut stays respected.
- Sync recovery respects raid and post-zone guards, spaces missing-chunk
  requests, ignores completed-transfer duplicates, and releases decode buffers
  sooner.
- Roster scans and note processing safely pause during protected content or
  inaccessible roster data; aborted scans do not immediately loop.
- Recruitment shortcuts avoid Blizzard friend menus to reduce protected-action
  taint affecting actions such as Visit House.

### Known issues

- None.
