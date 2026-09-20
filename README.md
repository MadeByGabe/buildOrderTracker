# BuildOrderTracker

A [Beyond All Reason](https://www.beyondallreason.info/) widget that records build events and per-second resource data during a match, then exports the results to TSV files for post-game analysis.

## Features

- Tracks every unit completion: what was built, which builder built it, when, and how long construction took
- Tracks which other builders assisted each build (guarding cons, nano turrets, the commander helping), and for how long
- Tracks when players reclaim their own finished units (e.g. wind turbines, to make room), with the reclaimer and how long it took
- Tracks feature reclaim (wrecks, rocks, trees) per second **and per reclaiming unit**, so you can tell what a given constructor actually brought in and when
- Records per-second snapshots of metal/energy income, expense, pull, excess, storage, and transfers between allies
- Tracks the build power actually in use (idle or stalled builders don't count)
- Accumulates total metal and energy produced, plus running averages
- Tracks the metal value of army and defences built
- Records energy converter capacity and use
- Appends extraction rate to MEX unit names (e.g. `Metal Extractor:2.40`)
- Records when the game was played, and lets you name the build order when exporting
- Provides a `/export_bo` chat command to write files at any point during or after the match

## Installation

Copy `buildOrderTracker.lua` into your BAR widgets folder:

```
Beyond All Reason/data/LuaUI/Widgets/
```

Enable the widget in-game via the widgets menu. It runs in three cases:

- spectating a live game: every player is tracked
- watching a replay: every player is tracked
- playing a practice game against an inactive AI: only your own team is tracked

While playing, a client may only read its own team's resources, so the widget removes itself in a real match. A practice game means nobody else is playing (other humans may spectate) and every other team is a skirmish AI that does nothing — the engine's `NullAI`, listed in the lobby as *Test AI using the new C interface* ("This AI does absolutely nothing"). A real AI (BARb, CircuitAI) or a Lua AI (Scavengers, Raptors, the Simple AIs) keeps the widget off; the chat message says which team disqualified the game.

Enable it before the game starts (or before starting the replay): it only records from the moment it is enabled, and the date the game was played is only available at game start.

## Usage

Type `/export_bo` in chat to write TSV files for every tracked player to:

```
Beyond All Reason/data/buildordertracker-builds/
```

Files are named using the player name, map name (shortened to 20 characters), and a timestamp from when the widget was loaded, for example:

```
builddata_PlayerName_some_map_name_20260415_183000.tsv
resourcedata_PlayerName_some_map_name_20260415_183000.tsv
reclaimdata_PlayerName_some_map_name_20260415_183000.tsv
```

The reclaim file is only written when something was reclaimed.

You can run `/export_bo` multiple times; each call overwrites the files for that session.

Any text after the command is saved as the build order's name in the files, e.g. `/export_bo commander tempo build`.

## Output Format

### Metadata line

The first line of every file starts with `#` and holds tab-separated `key=value` pairs:

| Key | Description |
|---|---|
| `version` | Export format version |
| `player` | Player name |
| `map` | Map name |
| `game` | Game name and version |
| `gameID` | Engine game ID |
| `played` | When the game started (local time), decoded from the game ID; `?` if unavailable |
| `exported` | When the export was made (local time) |
| `windMin`, `windMax` | The map's wind speed range; `?` if unavailable |
| `tidal` | The map's tidal strength; `?` if unavailable |
| `name` | Build order name given after `/export_bo`; omitted when there is none |

The column header row follows on the second line.

### `builddata_*.tsv`

One row per finished unit, plus one per reclaimed unit, sorted by start time.

| Column | Description |
|---|---|
| `unit_name` | Translated unit name followed by unit ID, e.g. `Wind Turbine (1234)`. MEXes include the extraction rate (`Metal Extractor:2.40 (1234)`). Reclaimed units start with `-` (`-Wind Turbine (1234)`) |
| `built_by` | Builder name and ID; for reclaims, the unit that reclaimed it. Empty if unknown. Assistants follow after a `:` (see below) |
| `start_time` | Game time when construction started, or when the reclaim started (seconds). If the start wasn't seen, the time it finished instead |
| `build_duration` | How long construction took, or how long the reclaim took (seconds). Empty if the start wasn't seen |
| `unit_def` | Internal unit name (e.g. `armwin`), the same in every game language |

#### Assistants

When other builders helped construct a unit, `built_by` lists their unit IDs after a `:`, comma-separated and sorted by ID:

```
Bot Lab (2436):11501,27409=2.1
```

- `11501` helped for the whole build (within 0.6 seconds or 5% of the build duration, whichever is larger), so no time is written
- `27409=2.1` helped for 2.1 seconds of it

The builder that started the unit is never listed as its own assistant. Time is sampled every 0.2 seconds, so short assists are approximate. It is time spent helping, not build power: multiply by the assistant's build speed to estimate its contribution. Reclaims have no assistants, and neither do units whose start wasn't seen. To split the cell, split on the first `):`.

### `resourcedata_*.tsv`

One row per game second. Stored values and build power are a snapshot at the start of the second; flows (income, expense, etc.) are for the previous second.

| Column | Description |
|---|---|
| `time` | Game second |
| `wind_speed` | Current wind speed |
| `metal_stored`, `energy_stored` | Resources currently in storage |
| `metal_income`, `energy_income` | Income per second |
| `metal_expense`, `energy_expense` | Actually spent per second |
| `metal_pull`, `energy_pull` | Demanded per second; above expense means stalling |
| `metal_excess`, `energy_excess` | Lost to full storage per second |
| `metal_received`, `energy_received` | Received from allies per second |
| `metal_sent`, `energy_sent` | Sent to allies per second |
| `build_power` | Build power actually in use: each builder's build speed times the fraction it applied, so builders that are walking, idle, or stalled count as zero or partial |
| `total_metal_produced`, `total_energy_produced` | Cumulative income since game start |
| `metal_average`, `energy_average` | Total produced divided by game seconds |
| `army_value_built` | Cumulative metal cost of finished armed mobile units (excluding commanders) |
| `defence_value_built` | Cumulative metal cost of finished armed static units |
| `total_metal_reclaimed`, `total_energy_reclaimed` | Cumulative resources this team's builders took from features (wrecks, rocks, trees) |
| `converter_capacity` | Energy the team's converters could turn into metal per second |
| `converter_use` | Energy they actually converted per second |

The army and defence values count what has been built; losses aren't subtracted.

Reclaim is part of `metal_income`/`energy_income`, not on top of it. The totals come from the game's team stats gadget, which counts every reclaim step on the synced side; in a game without that gadget both columns stay at zero, and no reclaim file is written. Reclaiming a *unit* is a separate thing, logged in `builddata_*.tsv`.

### `reclaimdata_*.tsv`

One row per game second per reclaiming unit per source, written only for seconds in which something was reclaimed. This is what answers questions like *"how much energy per second did that early Reclaim Bot actually bring in, and from when?"* — filter to one `reclaimer_id` and read off the rate.

| Column | Description |
|---|---|
| `time` | Game second |
| `reclaimer_id` | Unit ID of the builder credited, or `0` when it could not be attributed |
| `reclaimer` | Translated builder name, e.g. `Rez Bot`; empty when unattributed |
| `reclaimer_def` | Internal builder name, e.g. `armrectr`; empty when unattributed |
| `source` | `map` for what the map put down (trees, rocks), `wreck` for a unit's corpse, `unknown` when unattributed |
| `metal`, `energy` | Taken that second |

`reclaimer_id` joins to the builder's unit ID in `builddata_*.tsv`, so a reclaimer can be traced back to when and by what it was built.

#### How attribution works, and what it can't tell you

A widget can see neither the reclaim steps nor whose builder took a feature's resources — that only exists on the synced side. So the two halves come from different places: the team's running totals say **how much**, and polling each builder's current task five times a second says **who**. Each second's total is split over the builders seen reclaiming, weighted by the build power each had in use, and then split per builder between `map` and `wreck` in the same proportion.

This means:

- A builder with a reclaim order that is still walking to its target applies no build power and is credited nothing.
- When two builders reclaim at once, the split is proportional, not measured. With one reclaimer — the usual case early on, and the case the tool is aimed at — it is exact.
- Anything no builder was seen for, such as a tree taken apart entirely between two polls, is written under `reclaimer_id` `0` with source `unknown` rather than spread over whoever happened to be nearby. Nothing is invented, and a large `unknown` share is a signal to trust the per-unit rows less.
- Each second's rows add up exactly to that second's rise in `total_metal_reclaimed`/`total_energy_reclaimed`.
- Enabled mid-game, the running totals start at whatever the team had already reclaimed, but only what is reclaimed from then on gets per-unit rows.

## Author

Baldric — licensed under GNU GPL v2 or later.

Built with assistance from [Claude Code](https://claude.ai/code).
