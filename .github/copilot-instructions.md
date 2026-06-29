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

## Agent Workflow

### Task breakdown
- Decompose work into units where each unit is a single public function or behaviour callback, testable in isolation with a single ExUnit test module, before writing any code.
- Each unit should map to a single behaviour or code path, not a whole feature.
- State the unit you are working on before starting it.

### Test-driven development
- Write a failing test (or tests) for the unit first, then commit it.
- Implement only enough code to make those tests pass, then commit again.
- Never skip the red phase — the failing test commit is required.

### Branching
- Create a feature branch from `main` for each logical chunk of work (e.g. `feat/schema-articles`).
- Merge back to `main` only when all tests pass and `mix precommit` is clean.
- Delete the branch after merging.

### Progress tracking
- Each logical chunk of work must have a corresponding GitHub issue before a branch is created. If no corresponding GitHub issue exists when a branch is about to be created, stop and create the issue first (or ask the user to create it), then proceed. Do not create the branch without a linked issue number.
- Reference the issue number in the branch name (e.g. `feat/42-schema-articles`) and in the first commit message (e.g. `add failing tests for article changeset (#42)`).
- Open a draft pull request against `main` as soon as the branch has its first commit; this makes in-flight work visible.
- Promote the PR from draft when all tests pass and `mix precommit` is clean.
- Close the issue via the PR description (`Closes #42`) so GitHub links and closes it automatically on merge.

### Commits
- Commit after every meaningful, working state: failing tests, passing tests, refactor.
- Commit messages must be a single lowercase line, 72 chars max, imperative mood (e.g. `add failing test for article changeset`).
- Never bundle unrelated changes in one commit.
- Run `mix precommit` before any commit and fix all issues first.

### Autopilot mode
- Work autonomously through the task plan without asking for confirmation at each step.
- Stop and ask the user to verify before: merging to `main`, deleting branches, making destructive schema changes, or any action that is hard to reverse.
- Stop and report progress whenever a phase boundary is reached (as defined in `spec/05_implementation_plan.md`) or when all tests for a feature branch are passing and the PR is ready to promote from draft.

## Tool usage
- Prefer VS Code and GitHub Copilot tools over raw CLI commands for all operations where a tool equivalent exists.
- Fall back to CLI only when a tool is unavailable or demonstrably insufficient.

## Security
- Follow OWASP Top 10 practices throughout.
- For any authentication or authorisation feature: use Phoenix's built-in `mix phx.gen.auth` generator as the foundation; never roll bespoke session or password handling.
- Secrets must never be committed; use environment variables and `config/runtime.exs`.
- Always validate and sanitise data at system boundaries (controllers, LiveView event handlers, context public APIs).

1. Keep changes production-oriented and testable.
2. Respect existing project conventions in `AGENTS.md`.
3. When implementing planned work, follow phase order in `spec/05_implementation_plan.md`. If a user requests work from a later phase before earlier phases are complete, surface the out-of-order conflict explicitly and ask the user to confirm before proceeding. Do not silently skip phases.
