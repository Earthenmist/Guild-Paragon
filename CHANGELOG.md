# 1.9.0-Release

## Changes
- New login summary: shortly after you log in, a card lists what changed in the guild since you were last online on any of your characters, such as joins, leaves, rank changes, members reaching max level, returns after a break and note changes. One line per kind of change. Officer-only changes are shown to officers only.
- New notification bell in the window header; it glows when something new arrives. Its list shows what needs attention (applications awaiting review, recruits waiting for a welcome, Guild Finder listing expiring, Ban List matches), the guild changes you have not seen, and birthdays and anniversaries in the next 7 days. Click a line to jump to it; guild changes open the Event Log filtered to them.
- Application and Guild Finder reminders now join the login card instead of popping up separately. Officers get the card by default; members can turn it on. It waits until you are out of combat and instances. Options are under Settings > Logs & Sync > Notifications; "/gp summary" shows it again.
- Choose which kinds of change, reminders and upcoming dates the login card and bell include (Settings > Logs & Sync > Notifications).
- Roster: new Promote and Demote buttons on the member card move the selected member one rank per click, without a macro. A Kick button removes them after you type the guild name to confirm. Officers with permission only; not in combat.
- Reminder cards now stack instead of overlapping.
- Event Log: Remove is now Remove Event Line in a right-click menu, with Show in Roster.

## Fixes
- Checkboxes now use the Guild Paragon dark and teal style instead of the default Blizzard look.

## Known issues
- The summary starts tracking from your first login with this version, so the first login shows no guild changes.
