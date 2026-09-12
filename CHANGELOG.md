# Changelog

## 2026-09-12 - v1.3.3-Release

### Changes

- None

### Fixes

- Reduce roster refresh processing time by about 94% on average in local tests
  with search and audit filters inactive.
- Avoid hidden Companion preview rebuilds, reducing sync-status notification
  processing time by over 99.9% on average in local tests.
- Spread full-sync category sends and nickname replay across frames, and remove
  repeated nickname scans during replay preparation.
- Keep matching full-sync exchanges alive while new chunks arrive.
- Recover stale offline-peer blocks when valid traffic arrives. Generic whisper
  failures no longer mark players offline; diagnostics show the send result.
- Remove automatic addon-memory measurements from two sync-processing paths.
- Pause chat nickname/main hints during combat, protected instances and loading;
  leave secret-bearing messages untouched.

### Known issues

- None
