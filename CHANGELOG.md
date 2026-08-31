# Changelog

## 2026-08-31 - v1.2.2-Release

### Changes

- Roster Display settings now let users choose the two note-style columns shown
  in the Roster table: Note, Officer Note, Custom Note, or Custom Officer Note.
- The two Roster note-column dropdowns prevent duplicate sources so both
  columns always show different data.
- Non-officers automatically see Note and Custom Note when a saved selection
  points at officer-only data, avoiding blank officer-note columns.
- Guild Sync now sends explicit alt/main clear tombstones instead of treating a
  missing full-state value as a delete.

### Fixes

- Roster note-column changes refresh the table headers, rows, and sorting state
  immediately without requiring a reload.
- Roster Display settings now keep the new note-column controls and existing
  scan/combat/scale controls inside the panel.
- Roster note-column labels and helper text now align cleanly with the dropdowns.
- Full-state Guild Sync no longer unlinks alt/main records on recipient clients
  when a timestamp arrives without a matching link value.
- Full-state alt/main sync repair no longer creates local Event Log rows on the
  receiving client, while live remote alt/main updates log with actor
  attribution such as "OfficerName tagged Character-Realm as an alt of
  Main-Realm."
- Guild-master full-state sync can repair recipient alt/main records that were
  stamped by the earlier missing-value unlink bug.

### Known issues

- No known release-blocking defects after GM and non-officer live validation.
