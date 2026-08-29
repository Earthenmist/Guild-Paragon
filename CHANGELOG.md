# Changelog

## 2026-08-29 - v1.2.0-Release

### Changes

- Guild Health now uses page-specific access: members can use Recruitment,
  Housing, and Upcoming Dates while officer summaries remain restricted.
- Linked characters share one guild nickname; `My Alias` is private and local.
- Upcoming Dates lists birthdays/anniversaries with filters, copy greetings,
  and deliberate guild-calendar event creation.
- Backups now have integrity metadata plus manual, automatic, and pre-restore
  classes. Automatic backups are local, off by default, and never sync.
- Restore Preview reports risks before confirmation; snapshot and comparison
  work is spread across frames.

### Fixes

- Fixed full-state nickname sync errors after equal or older peer records.
- Restores require the verified current guild master and a successful
  pre-restore safety snapshot.
- Completed restores request a user-clicked reload.
- Snapshot creation aborts if roster or Guild Sync data changes mid-copy.
- Housing visit overlays now disarm after use and on close, so Roster
  addresses and Guild Health map pins do not leave invisible hitboxes.
- Stale auto-main sync from Beta or stable clients can no longer clear
  deliberate alt/main links; explicit officer links keep priority.
- Guild Sync peer activity details now wrap over two lines, and received-state
  summaries use shorter wording.
- Guild Sync release diagnostics now hide routine empty/no-op lines and tolerate
  missing debug reasons.

### Known issues

- No known release-blocking defects at promotion.
