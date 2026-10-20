# Guild Paragon

Guild Paragon is a modern guild management addon for Retail World of Warcraft and the WoW Forever beta, built to make keeping track of your guild easier without turning everything into an officer-only tool.

It brings together roster management, alt and main tagging, nicknames, guild history, recruitment, syncing and officer tools in one place.

Guild Paragon isn't just for officers either. Regular guild members can browse the roster, view linked characters and manage their own safe profile information, while officer-only information and actions remain restricted to the appropriate ranks.

***

## ✨ Features

Guild Paragon gives you a much more useful view of your guild than the standard WoW roster.

You can:

*   Search and browse your guild roster.
*   Keep track of shared guild nicknames, private personal aliases, birthdays,
    join dates, mains and alts.
*   See recent guild history including joins, leaves, rank changes and other activity.
*   Add custom Guild Paragon notes without replacing Blizzard guild notes.
*   Read Blizzard guild and officer notes alongside your custom notes, subject to guild permissions, with separate Recent History and Audit Details flyouts.
*   Use optional chat hints to make it easier to recognise who is speaking when someone is on an alt.
*   Sync shared Guild Paragon data with other guild members running the addon.
*   Browse guild chat and, on Retail, guild professions and shared recipes.
*   Review Guild Health pages for attention items, recruitment, housing,
    upcoming birthdays and guild anniversaries.
*   Use recruitment, logging, backup and guild management tools if you have the required guild permissions.

***

## 👥 For Guild Members

You don't need to be an officer to make use of Guild Paragon.

Guild members can:

*   Browse the guild roster and member profiles.
*   View mains, alts and linked characters.
*   Add or update their nickname, private alias and birthday.
*   View member-facing Guild Health pages such as Recruitment, Housing and
    Upcoming Dates when guild permissions allow.
*   Quickly move between linked-character profiles.
*   Enable chat hints showing nicknames, mains and alts.
*   Open Guild Paragon from the minimap button, Addon Compartment or `/gp`.
*   Optionally use the standard guild shortcut to open Guild Paragon outside combat. Enable it in General Settings and reload.
*   Use a minimap button collector to organise the Guild Paragon button.
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
*   Review Blizzard Guild Finder applications on Retail.
*   A Ban List and Recruitment Do Not Invite list.
*   Manually invite a player from their recruitment Antispam cooldown entry when they reply, without retyping their name or removing the cooldown.
*   Macro Tool support for actions such as kicks, promotions, demotions and alt-rank alignment.
*   A Macro Tool execution shortcut configurable in Blizzard Keybindings under Guild Paragon.
*   Manual, automatic and pre-restore backups through Settings > Backup &
    Restore, with Guild Master controls for destructive restore actions.
*   Roster, Guild Health and Event Log exports in TSV format.

***

## ✅ Designed With Guild Safety in Mind

Guild Paragon respects the supported client's addon restrictions and keeps protected guild actions under player control.

That means:

*   Officer-only sections are hidden from members who shouldn't have access to them.
*   Officer-sensitive information isn't displayed or synced to non-officers.
*   Recruitment scans and queued execution are started by the player, throttled and easy to stop. Where required, each next `/who` query needs a button press.
*   Backups remain local and are not sent through Guild Sync.
*   Guild actions created by the Macro Tool are normal visible WoW macros that the officer presses themselves.
*   Destructive actions require confirmation.
*   Protected actions, combat restrictions and unavailable Blizzard API information are handled conservatively.

The aim is to make guild administration easier without taking control away from the player.

***

## 🧭 Main Sections

| Section          |What it's for                                                                                |
| ---------------- |-------------------------------------------------------------------------------------------- |
| <strong>Roster</strong> |Guild members, profiles, notes, nicknames, aliases, birthdays, mains, alts, labels and roster actions |
| <strong>Guild Health</strong> |Overview, attention items, recruitment health, housing, upcoming dates and exports           |
| <strong>Guild Chat</strong> |Guild conversation, with history where the client supports it                              |
| <strong>Professions</strong> |Retail guild primary professions, member search and Blizzard recipe views                    |
| <strong>Event Log</strong> |Searchable guild history with filters, exports and cleanup tools                             |
| <strong>Recruitment</strong> |Scanning, filters, templates, queues, follow-ups and recruitment statistics                  |
| <strong>Applications</strong> |Retail Blizzard Guild Finder applications and permitted officer responses                  |
| <strong>Ban List</strong> |Ban records, Do Not Invite entries, spam protection and rejoin warnings                      |
| <strong>Guild Sync</strong> |Sync status, peer progress, shared data categories and manual Event Log replacement          |
| <strong>Macro Tool</strong> |Builds visible WoW macros for supported officer guild actions                                |
| <strong>Settings</strong> |UI options, chat hints, roster settings, Guild Health, Backup &amp; Restore, logging, sync and recruitment |
| <strong>Help</strong> |Commands, explanations and addon information                                                 |

***

## 🔄 How Guild Sync Works

On login or reload, Guild Paragon compares supported data categories with compatible online addon users and transfers the differences. Edits then sync live; there are no scheduled full or catch-up snapshots. All participants should keep the addon updated.

Version 1.7.0 uses native compression and paced addon messages while retaining IBLT-based difference comparisons. Improved transport and category ordering reduced a clean two-client sync from 80 minutes to about 26 minutes in testing; actual times depend on the data, connection and available sync time. All participants need 1.7.0 or later; earlier releases and test builds use separate transports.

Guild Health and New Member Follow-up policy is controlled by the guild master and synced directly from them. Other members see read-only settings. Failed alt/main updates show affected characters and recovery advice when hovering the peer in Guild Sync; other categories continue while conflicts need attention. After correcting the problem, use **Sync Now** to retry.

Interrupted checks retain progress and retry when peers are available. Offline players are removed from active sync work, and waiting for one player's acknowledgement does not block outgoing traffic to everyone else. The Guild Sync page shows category progress, received updates and reasons for deferred checks.

Players can continue playing normally. Sync pauses during combat, restricted instances and zone transitions, then resumes when safe. Housing neighbourhoods, including Founder's Point, and house interiors are allowed outside those restrictions. Below 25 FPS, smaller batches and slower outgoing pacing let sync continue, including when WoW is in the background with **Max Background FPS** enabled.

Existing guild permissions determine which data each player can send or receive. Private aliases and local backups are not shared. **Event Log replacement is a separate manual action**, not part of automatic sync.

***

## 🛠️ Guild Professions — Retail

Browse the guild's primary professions, search members and open the recipes Blizzard makes available. Offline members are shown by default; select **Hide Offline Members** to narrow the list. Gathering professions remain listed, with recipe buttons hidden where they do not apply.

***

## 🧩 Optional Companion

Guild Paragon also supports optional Guild Paragon Companion integration through **Settings > Companion**. Companion data is supplied by a separate **Guild Paragon Companion Data** addon; it is not required to use Guild Paragon. See the in-game settings and Discord for setup information.

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
| <code>/gp client</code> |Show client compatibility information       |
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

You can also download releases from CurseForge, Wago or the [GitHub releases page](https://github.com/Earthenmist/Guild-Paragon/releases).

### Manual Installation

1.  Download the latest Guild Paragon `.zip`.

2.  Extract it into:

    `World of Warcraft/_retail_/Interface/AddOns/`

    For WoW Forever, use that client's `Interface/AddOns/` folder instead.

3.  Make sure the addon folder is called:

    `GuildParagon`

4.  Restart World of Warcraft if it is already running.

***

## 🧩 Compatibility

*   **Clients:** Retail World of Warcraft (Midnight) and the WoW Forever beta, in one addon package. Other Classic variants are not supported.
*   **Client differences:** Retail-only features such as Guild Finder applications, guild professions and housing are hidden or unavailable in Forever. Forever recruitment uses its own race, class and default invalid-zone choices, and full character names are handled without adding Retail realm suffixes.
*   **Language:** English. Other client locales currently use English fallback text.
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
