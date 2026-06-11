# Starter Decisions

- Record only decisions that materially affect future implementation or maintenance.
- Include the date, the decision, and a brief rationale in each new entry.
- Prefer updating an existing decision entry when replacing prior guidance instead of duplicating it.
- 2026-05-26: Phase 1 is analysis-only capture with broad parameter-grid sweeps before any JSFX generation; rationale is to preserve full interaction data for later modeling without premature DSP fitting.
- 2026-05-26: Parameter-grid capture writes both CSV (measurements) and .meta.json (run metadata + combo definitions); rationale is to make offline analysis reproducible without parsing only console/UI state.
- 2026-05-26: Provide both standalone scripts and a ReaImGui workbench launcher; rationale is to keep automation modular for reliability while offering one-window operation.
- 2026-05-26: Capture run control/status uses Reaper ExtState (single-run guard, cancel flag, heartbeat progress) between UI and backend capture loop; rationale is to prevent overlapping runs and provide visible stop/status without blocking the UI thread.
- 2026-05-26: Added per-combo analyzer reset handshake (force Source idle, settle window, then arm/start level) before each combo; rationale is to avoid missed run-edge transitions that can stall captures at combo boundaries.
- 2026-05-26: Added workspace-local custom agent files under `.github/agents/` with model assignments by role; rationale is to make reasoning-heavy review/architecture use the strongest reasoning model and implementation/UI work use the coding-oriented model.
- 2026-05-27: Added IGR_PluginBypassManager_ReaImGui as an exact-name project-wide FX bypass tool; rationale is to avoid fuzzy-match accidents when bulk-bypassing repeated plugin instances across many tracks.