# Guild Paragon

Guild Paragon is a modern guild management addon for Retail World of Warcraft, built to make keeping track of your guild easier without turning everything into an officer-only tool.

It brings together roster management, alt and main tagging, nicknames, guild history, recruitment, syncing and officer tools in one place.

Guild Paragon isn't just for officers either. Regular guild members can browse the roster, view linked characters and manage their own safe profile information, while officer-only information and actions remain restricted to the appropriate ranks.

***

## ✨ Features

Guild Paragon gives you a much more useful view of your guild than the standard WoW roster.

You can:

*   Search and browse your guild roster.
*   Keep track of nicknames, birthdays, join dates, mains and alts.
*   See recent guild history including joins, leaves, rank changes and other activity.
*   Add custom Guild Paragon notes without replacing Blizzard guild notes.
*   Use optional chat hints to make it easier to recognise who is speaking when someone is on an alt.
*   Sync shared Guild Paragon data with other guild members running the addon.
*   Use recruitment, logging, backup and guild management tools if you have the required guild permissions.

***

## 👥 For Guild Members

You don't need to be an officer to make use of Guild Paragon.

Guild members can:

*   Browse the guild roster and member profiles.
*   View mains, alts and linked characters.
*   Add or update their nickname and birthday.
*   Quickly move between linked-character profiles.
*   Enable chat hints showing nicknames, mains and alts.
*   Open Guild Paragon from the minimap button, Addon Compartment or `/gp`.
*   Access the in-game Help section.

Officer information remains hidden where appropriate.

***

## 🛡️ For Officers

Officers get access to the wider set of guild management tools.

These include:

*   Guild Paragon custom notes and officer-only custom notes.
*   Custom labels such as **Trial**, **Casual Raider** or **Serious Raider**.
*   Roster filtering and searching by those labels.
*   Main and alt tagging, including explicit main markers and tools for cleaning up untagged characters.
*   A searchable Event Log covering joins, leaves, rank changes, notes, birthdays, alt changes, nicknames, level-ups, inactive members returning and ban warnings.
*   Guild Sync for sharing supported roster, profile, recruitment, macro and ban information between officers.
*   Recruitment scanning, queues, whispers, invites, follow-ups and recruitment statistics.
*   A Ban List and Recruitment Do Not Invite list.
*   Macro Tool support for actions such as kicks, promotions, demotions and alt-rank alignment.
*   Manual backups and restore points.
*   Roster and Event Log exports in TSV format.

***

## ✅ Designed With Guild Safety in Mind

Guild Paragon works within Blizzard's Retail addon restrictions rather than trying to automate protected guild actions.

That means:

*   Officer-only sections are hidden from members who shouldn't have access to them.
*   Officer-sensitive information isn't displayed or synced to non-officers.
*   Recruitment actions remain manual, throttled and easy to stop.
*   Guild actions created by the Macro Tool are normal visible WoW macros that the officer presses themselves.
*   Destructive actions require confirmation.
*   Protected actions, combat restrictions and unavailable Blizzard API information are handled conservatively.

The aim is to make guild administration easier without taking control away from the player.

***

## 🧭 Main Sections

| Section          |What it's for                                                                                |
| ---------------- |-------------------------------------------------------------------------------------------- |
| <strong>Roster</strong> |Guild members, profiles, notes, nicknames, birthdays, mains, alts, labels and roster actions |
| <strong>Event Log</strong> |Searchable guild history with filters, exports and cleanup tools                             |
| <strong>Recruitment</strong> |Scanning, filters, templates, queues, follow-ups and recruitment statistics                  |
| <strong>Guild Sync</strong> |Sync status, progress, shared data categories and Event Log syncing                          |
| <strong>Macro Tool</strong> |Builds visible WoW macros for supported officer guild actions                                |
| <strong>Ban List</strong> |Ban records, Do Not Invite entries, spam protection and rejoin warnings                      |
| <strong>Backup &amp; Restore</strong> |Manual restore points with confirmation before restoring                                     |
| <strong>Export &amp; Stats</strong> |Copyable roster and Event Log data                                                           |
| <strong>Settings</strong> |UI options, chat hints, roster settings, logging, sync, recruitment and diagnostics          |
| <strong>Help</strong> |Commands, explanations and addon information                                                 |

***

## 💬 Slash Commands

| Command         |What it does                                |
| --------------- |------------------------------------------- |
| <code>/gp</code> |Open or close Guild Paragon                 |
| <code>/guildparagon</code> |Alias for <code>/gp</code>                  |
| <code>/gp scan</code> |Request a roster scan                       |
| <code>/gp roster</code> |Print a compact roster summary              |
| <code>/gp log [count]</code> |Show recent Event Log entries               |
| <code>/gp perf</code> |Show performance diagnostics                |
| <code>/gp minimap</code> |Toggle the minimap button                   |
| <code>/gp fulllog</code> |Request a manual full Event Log replacement |

There are also additional maintenance and import commands listed in the in-game Help section. Some of these are only available to officers or the Guild Master.

***

## 📥 Importing From GRM

Having used Guild Roster Manager for over eight years, adding an import option felt like a sensible way to make moving to Guild Paragon easier. Supported GRM data can be imported where it is available, helping existing users bring their guild information across without starting from scratch.

This can include:

*   Current and former guild members
*   Main and alt relationships
*   Nicknames
*   Custom notes
*   Birthdays
*   Ban List entries
*   Guild history/log information

The Guild Master will perform a dry-run first to see what will be imported before making any changes.

***

## 📦 Installation

### CurseForge

The easiest way to install Guild Paragon is through the CurseForge app.

You can also download the latest release manually from CurseForge.

### Manual Installation

1.  Download the latest Guild Paragon `.zip`.

2.  Extract it into:

    `World of Warcraft/_retail_/Interface/AddOns/`

3.  Make sure the addon folder is called:

    `GuildParagon`

4.  Restart World of Warcraft if it is already running.

***

## 🧩 Compatibility

*   **Game:** Retail World of Warcraft
*   **Era:** The War Within / Midnight-ready
*   **Dependencies:** None required — the libraries Guild Paragon uses are included with the addon.

***

## 💬 Support

If you've found a bug, have a feature suggestion, want to see upcoming changes or would like access to beta builds, you're welcome to join the official Discord:

**Earthenmist - Addon Hub**

[https://discord.gg/U8mKfHpeeP](https://discord.gg/U8mKfHpeeP)

***

## 📜 License

All Rights Reserved.

***

## ❤️ Credits

**Author:** Earthenmist

Guild Paragon is developed, tested and maintained by Earthenmist. AI-assisted development tools are used where helpful for coding, debugging and documentation, but the direction, decisions and final implementation remain human-led.
