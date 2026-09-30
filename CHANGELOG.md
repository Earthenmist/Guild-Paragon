# 1.6.1-Release

## Changes
- Improved sync for players who alt-tab or run WoW in the background with Max Background FPS enabled. If frame rates fall below 25 FPS, sync now continues with smaller work batches and slower outgoing pacing instead of pausing until FPS improves.
- Guild Sync now explains why a comparison was deferred, including missing acknowledgements, reply timeouts and busy peers.

## Fixes
- Sync uses roster online/offline updates to stop attempts to unavailable players and resume checks when they return.
- Waiting for one player's acknowledgement no longer blocks outgoing updates to other players.
- Failed comparisons discard stale requests and back off repeated attempts, leaving available peers more opportunity to sync.
- Online roster members no longer appear probably offline merely because they have no recent sync activity.

## Known issues
- None currently known.
