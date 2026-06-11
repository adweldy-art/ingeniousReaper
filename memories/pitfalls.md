# Starter Pitfalls

- Do not assume documentation matches runtime behavior; verify the live code path first.
- Do not treat passing tests alone as proof after broad edits; inspect the changed surface directly.
- Do not overwrite existing memory files during bootstrap; seed only files that are still missing.
- Do not store speculative lessons as memory; keep only confirmed patterns and failures.
- JSFX parser may reject scientific notation constants in some contexts (e.g., `1e-12` in `@init`); use explicit decimal literals for tiny constants when compile errors appear.
- ReaImGui `ImGui_Combo` in this environment expects a null-delimited item string (not a Lua table), and input widgets return `(changed, value)`; treating return values as `value` only can silently corrupt UI state.
- Capture loops can stall on combo transitions if Source Run is toggled off/on in the same control tick; use a two-step arm-then-start handshake to guarantee a visible run-edge in JSFX.