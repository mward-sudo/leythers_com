# Repository Context Instructions

Use this file as the default project context for GitHub Copilot in this repository.

## Primary Context Files

Read these first before implementing major changes:

1. `spec/context/project_context.md`
2. `spec/context/implementation_context.md`
3. `spec/05_implementation_plan.md`
4. `spec/06_acceptance_criteria.md`

If any Primary Context File is missing or unreadable, stop and ask the user to provide the missing file before proceeding with implementation.

## Repository Constraints

1. OTP app name is `:leythers_com`.
2. Use `LeythersCom.*` module namespaces and `lib/leythers_com/...` file paths.
3. Prefer migrations and Ecto schemas aligned with `spec/03_data_model.md`.
4. Fast-track manual publish path must bypass Oban and LLM calls.
5. Generation path must enforce budget controls defined in spec docs.

## Delivery Expectations

1. Keep changes production-oriented and testable.
2. Respect existing project conventions in `AGENTS.md`.
3. When implementing planned work, follow phase order in `spec/05_implementation_plan.md`.
