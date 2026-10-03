# 1.7.0-Release

## Changes
- Switched to native sync transport and improved category priority, reducing clean-sync time by about 68% in our two-client tests (80 minutes to about 26 minutes). IBLT-based comparison is retained, so only differences are transferred.
- Sync now prioritises former members, alts/mains, nicknames, join dates, birthdays, general notes, officer notes, macro rules and macro ignores, followed by the remaining categories.
- Guild Health and New Member Follow-up settings are now guild-master controlled and sync to members as read-only settings.
- Guild Sync shows clearer failure details, affected characters and recovery advice. Categories needing attention no longer hold up the others.
- All participants need 1.7.0 or later to use the new sync transport.

## Fixes
- Fixed mismatched alt/main counts and unnecessary comparisons caused by obsolete timestamps and equivalent legacy data.
- Failed alt/main updates no longer report successful completion. Temporary failures retry; persistent conflicts show Needs attention and can be retried after correction.

## Known issues
- None currently identified.
