# ingeniousReaper

A collection of REAPER scripts and ReaPack-compatible packages for recording, tempo workflow, and track/file utility tasks.

## Overview

This repository contains Lua scripts for the [REAPER](https://www.reaper.fm/) digital audio workstation. The scripts are organized for distribution through ReaPack and currently focus on:

- building or aligning tempo maps from click tracks
- importing files onto matching tracks
- scheduling recording sessions
- automatic gain staging of selected tracks with JSFX trim control

Repository description: **reaper scripts and jsfx plugins**.

## Included scripts

### Tempo
- **GetClickTempo.lua** — Build a tempo map from a recorded click track.
- **TempoToClickAlign.lua** — Align an existing tempo map to click track transients.

### Tracks
- **ImportLCC.lua** — Import files to same-named tracks at project start.
- **AutoGainStageToJSFX.lua** — Analyze selected tracks (RMS/Peak/Crest) and write trim commands to a JSFX via gmem.
- **IGR_PluginBypassManager_ReaImGui.lua** — Scan the project, choose a plugin name, and bypass or re-enable all matching instances.

### JSFX
- **IGR_StageTrim_gmem.jsfx** — Track trim effect controlled by ReaScript over gmem.

### Recording
- **ScheduleRecord.lua** — Scheduled recorder with persistent multi-schedule support.

## Repository structure

```text
.
├── Reaper-Scripts/
│   ├── AutoGainStageToJSFX.lua
│   ├── GetClickTempo.lua
│   ├── ImportLCC.lua
│   ├── ScheduleRecord.lua
│   └── TempoToClickAlign.lua
├── Reaper-JSFX/
│   └── IGR_StageTrim_gmem.jsfx
├── index.xml
└── README.md
```

## ReaPack support

This repository includes a ReaPack index file:

- `index.xml`

If you use ReaPack, you can add this repository by pointing ReaPack to the raw URL of the index file:

```text
https://raw.githubusercontent.com/adweldy-art/ingeniousReaper/main/index.xml
```

## Requirements

- [REAPER](https://www.reaper.fm/)
- ReaPack (recommended for installation and updates)

## Installation

### Option 1: Install through ReaPack
1. Open REAPER.
2. Open **Extensions > ReaPack > Import repositories...**
3. Add the raw `index.xml` URL shown above.
4. Synchronize packages.
5. Browse and install the scripts you want.

### Option 2: Manual installation
1. Download the `.lua` scripts from the `Reaper-Scripts/` directory.
2. Copy them into your REAPER scripts folder.
3. In REAPER, open the **Actions** list.
4. Load or import the scripts manually.

## Usage

After installation:
1. Open REAPER.
2. Launch the **Actions** list.
3. Search for the script by name.
4. Run it on the relevant project, track, or media items depending on the script.

Because each script serves a different workflow, check the script name and description in ReaPack or REAPER's Actions list for the best starting point.

## Versioning

Current package versions listed in `index.xml`:

- `GetClickTempo.lua` — `0.1`
- `TempoToClickAlign.lua` — `0.1`
- `ImportLCC.lua` — `0.1.2`
- `ScheduleRecord.lua` — `0.1`
- `AutoGainStageToJSFX.lua` — `0.1`
- `IGR_PluginBypassManager_ReaImGui.lua` — `0.1`
- `IGR_StageTrim_gmem.jsfx` — `0.1`

## Author

Package author listed in the ReaPack index: **ingeniousWizard**

## Contributing

Issues and pull requests are welcome if you want to improve scripts, fix bugs, or expand the package set.
