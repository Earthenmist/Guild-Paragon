# Changelog

## 2026-09-15 - v1.3.4-Release

### Changes

- Increase simultaneous full/safety sync receive capacity from three to seven peers.
- Add interface 120105 support alongside 120100 following initial PTR testing.

### Fixes

- Reduce pauses when preparing large guild sync transfers with faster compression.
- Reduce repeated nickname and alt/main processing during roster updates.
- Retry deferred or interrupted syncs after about 15–20 seconds between updated
  clients, with clearer status messages. Older clients may still require longer waits.
- Fix members incorrectly remaining online after restarting the client or computer.

### Known issues

- None
