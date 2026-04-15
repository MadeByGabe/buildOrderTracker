# BuildOrderTracker

A [Beyond All Reason](https://www.beyondallreason.info/) widget that records build events and per-second resource data during a match, then exports the results to TSV files for post-game analysis.

## Features

- Tracks every unit completion: what was built, which builder built it, when, and how long construction took
- Records per-second snapshots of metal/energy income, expense, and storage
- Tracks active build power (builders currently assigned to a task)
- Accumulates total metal and energy produced, plus running averages
- Tracks total military value (metal cost of finished armed units) and its time-weighted average
- Appends extraction rate to MEX unit names (e.g. `Metal Extractor:2.40`)
- Provides an in-game **Export** button to write files at any point during or after the match

## Installation

Copy `buildOrderTracker.lua` into your BAR widgets folder:

```
Beyond All Reason/data/LuaUI/Widgets/
```

Enable the widget in-game via the widgets menu.

## Usage

An **Export** button appears at the right of the screen. Click it to write TSV files to:

```
Beyond All Reason/data/buildordertracker-builds/
```

Files are named using the player/team name, map name, and a timestamp from when the game started, for example:

```
builddata_PlayerName_some_map_name_20260415_183000.tsv
resourcedata_PlayerName_some_map_name_20260415_183000.tsv
```

You can click Export multiple times; each call overwrites the files for that session.

## Output Format

### `builddata_*.tsv`

One row per finished unit.

| Column | Description |
|---|---|
| `unit_name` | Translated unit name; MEXes include extraction rate (e.g. `Metal Extractor:2.40`) followed by unit ID |
| `built_by` | Builder unit name and ID |
| `time` | Game time when the unit finished (seconds) |
| `build_duration` | How long construction took (seconds) |

### `resourcedata_*.tsv`

One row per game-second.

| Column | Description |
|---|---|
| `time` | Game second |
| `wind_speed` | Current wind speed |
| `metal_stored` | Metal currently stored |
| `energy_stored` | Energy currently stored |
| `metal_income` | Metal income this second |
| `energy_income` | Energy income this second |
| `metal_expense` | Metal expense this second |
| `energy_expense` | Energy expense this second |
| `build_power` | Total active build power |
| `total_metal_produced` | Cumulative metal income since game start |
| `total_energy_produced` | Cumulative energy income since game start |
| `metal_average` | Average metal income per second |
| `energy_average` | Average energy income per second |
| `total_military_value` | Cumulative metal cost of all finished armed units |
| `time_weighted_military_avg` | Time-weighted integral of military value (production rate proxy) |

## Author

Baldric — licensed under GNU GPL v2 or later.

Built with assistance from [Claude Code](https://claude.ai/code).