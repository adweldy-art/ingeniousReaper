# Agent Routing

Workspace-local custom agents live in `.github/agents/`.

## Current Assignments

- Architect: GPT-5.4 (copilot)
- Reviewer: GPT-5.4 (copilot)
- Engineer: Claude Sonnet 4.6 (copilot)
- UX Designer: Claude Sonnet 4.6 (copilot)

## Rationale

- Use the stronger reasoning model for architecture and review work.
- Use the coding-oriented model for implementation and UI iteration.
- Keep the definitions local so the workspace has an explicit, reviewable routing policy.

## Notes

- If a different model is preferred in Copilot, these agent files can be edited without touching the codebase.
- These assignments are advisory within the workspace-local custom agent setup.