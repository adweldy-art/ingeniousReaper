# Starter Conventions

- Keep fixes focused on the root cause instead of layering surface patches.
- Preserve existing style and public APIs unless the task requires a deliberate change.
- Validate the edited surface directly after changes with the smallest reliable check.
- Add new memory entries only after the pattern or lesson has been verified in the codebase.
- Workspace-local custom agents can live in `.github/agents/*.agent.md` with `model` frontmatter to route reasoning vs implementation work by role.
- 2026-05-27: ReaImGui project-scan pickers in this repo should use exact FX names from live TrackFX enumeration, null-delimited combo strings, and a single Undo/PreventUIRefresh wrapper for bulk FX state changes.