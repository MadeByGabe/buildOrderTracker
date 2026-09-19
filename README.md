# BuildOrderTracker

A [Beyond All Reason](https://www.beyondallreason.info/) widget that records build events and per-second resource data during a match, then exports the results to TSV files for post-game analysis.

## Features

- Tracks every unit completion: what was built, which builder built it, when, and how long construction took
- Tracks when players reclaim their own finished units (e.g. wind turbines, to make room), with the reclaimer and how long it took
- Records per-second snapshots of metal/energy income, expense, pull, excess, storage, and transfers between allies
- Tracks the build power actually in use (idle or stalled builders don't count)
- Accumulates total metal and energy produced, plus running averages
- Tracks the metal value of army and defences built
- Appends extraction rate to MEX unit names (e.g. `Metal Extractor:2.40`)
- Records when the game was played, and lets you name the build order when exporting
- Provides a `/export_bo` chat command to write files at any point during or after the match

## Installation

Copy `buildOrderTracker.lua` into your BAR widgets folder:

```
Beyond All Reason/data/LuaUI/Widgets/
```

Enable the widget in-game via the widgets menu. The widget only runs while spectating a live game or watching a replay; it removes itself when you are playing.

Enable it before the game starts (or before starting the replay): it only records from the moment it is enabled, and the date the game was played is only available at game start.

## Usage

Type `/export_bo` in chat to write TSV files for every player to:

```
Beyond All Reason/data/buildordertracker-builds/
```

Files are named using the player name, map name (shortened to 20 characters), and a timestamp from when the widget was loaded, for example:

```
builddata_PlayerName_some_map_name_20260415_183000.tsv
resourcedata_PlayerName_some_map_name_20260415_183000.tsv
```

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
| `name` | Build order name given after `/export_bo`; omitted when there is none |

The column header row follows on the second line.

### `builddata_*.tsv`

One row per finished unit, plus one per reclaimed unit, sorted by start time.

| Column | Description |
|---|---|
| `unit_name` | Translated unit name followed by unit ID, e.g. `Wind Turbine (1234)`. MEXes include the extraction rate (`Metal Extractor:2.40 (1234)`). Reclaimed units start with `-` (`-Wind Turbine (1234)`) |
| `built_by` | Builder name and ID; for reclaims, the unit that reclaimed it. Empty if unknown |
| `start_time` | Game time when construction started, or when the reclaim started (seconds). If the start wasn't seen, the time it finished instead |
| `build_duration` | How long construction took, or how long the reclaim took (seconds). Empty if the start wasn't seen |
| `unit_def` | Internal unit name (e.g. `armwin`), the same in every game language |

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

The army and defence values count what has been built; losses aren't subtracted.

## Author

Baldric — licensed under GNU GPL v2 or later.

Built with assistance from [Claude Code](https://claude.ai/code).
