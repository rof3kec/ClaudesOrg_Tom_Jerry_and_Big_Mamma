# TASKS.md — Task Queue Format

This project uses an automated task processing system. Tasks are defined in `TASKS.md` and executed by autonomous Claude Code workers.

## Task Statuses

```
[ ] Pending     — waiting to be picked up
[!] In Progress — a worker is actively executing this (DO NOT edit)
[q] Ready for QA — work done, waiting for Spike to validate (DO NOT edit)
[x] Completed   — validated by Spike and finished successfully
[-] Failed      — execution failed (check logs, rewrite, change back to [ ] to retry)
```

## Format Rules

- Each task starts with a status marker at **column 0** (no leading whitespace)
- Do NOT use markdown list syntax (not `- [ ]`, not `* [ ]`)
- Multi-line tasks: indent continuation lines with spaces
- Tasks are processed **top-to-bottom**
- One logical unit of work per task

## Example

```
[ ] Add a GET /api/v1/health endpoint in src/routes/health.ts
    that returns { status: "ok", timestamp: Date.now() }.
    Register the route in src/routes/index.ts.

[ ] Fix the bug in src/utils/date.ts where formatDate() crashes
    on null input. Add a null check that returns "N/A".

[x] Set up ESLint configuration

[-] Migrate database schema (needs rewrite — missing table name)
```

## Writing Good Tasks

- **Be specific**: include file paths, function names, expected behavior
- **Be self-contained**: include enough context that someone unfamiliar with the codebase could complete it
- **Keep tasks independent**: tasks that touch different files/directories can run in parallel
- **One thing per task**: don't combine unrelated changes

## How Processing Works

1. The primary worker scans `TASKS.md` for the first `[ ]` line
2. Marks it `[!]` and executes it via Claude Code
3. On success: marks `[q]` (ready for QA) — on failure: marks `[-]`
4. Moves to the next `[ ]` task
5. Independent tasks may be executed in parallel by additional workers in isolated git worktrees
6. Spike (QA worker) validates `[q]` tasks (build, lint, type-check) — on pass: promotes to `[x]`, on fail: injects fix tasks
7. A supervisor commits and pushes validated work, then cleans completed tasks from the file

## Adding Tasks While Running

Append new `[ ]` lines at the bottom of `TASKS.md` at any time. Workers will pick them up on the next cycle. **Never edit lines marked `[!]`** — a worker is actively using them.
