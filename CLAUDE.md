# CLAUDE.md — Sierra Morning Dashboard

Project orientation, hard rules, and the orchestration policy for this project.
**Read HANDOFF-CURRENT.md first** (what to do next, what's blocked, and the traps), then DECISIONS.md
(every business rule + why), then WHERE-WE-ARE.md (status) and SPEC.md (how to build each metric).

## Project hard rules (never violate)

1. **Fail loud, never guess.** If an API call fails or data is missing, the dashboard says so
   on screen — never a stale, cached, or made-up number. A real zero must look different from an error.
2. **Don't hard-code targets/goals.** Raw numbers only; any targets are read from config.json at
   runtime (a later add-on), never baked into code.
3. **Keep the three layers separate:** `lib/st-common.ps1` = data (auth/paging/timezone/catalogs),
   `lib/metrics.ps1` = math (one `Get-Metric-*` fn + `$METRIC_DEFS`), `serve.ps1` + `dashboard.html`
   = presentation. Adding a metric = new function + registry entry + tab render; don't blur layers.
4. **All day boundaries are Pacific (America/Los_Angeles)** converted to a UTC range for API filters;
   never bucket by the raw UTC date.
5. **Credentials:** `secrets.json` is gitignored — never commit, email, or paste credentials.
6. **Doc roles stay separate:** DECISIONS.md = every business rule + why (read first); WHERE-WE-ARE.md =
   status; SPEC.md = build spec per metric; API-COVERAGE.md = what the API can/can't do. Keep them distinct.
   Where SPEC.md and DECISIONS.md disagree, DECISIONS.md wins (SPEC.md is stale for M2/M3/M4).
7. **Never page this tenant's API at pageSize=300.** The payroll endpoint returns byte-identical duplicate
   rows across page boundaries at exactly that value (200 and 2500 are clean). It silently inflated every
   overtime figure by ~28-39% until 2026-08-03. Verify filter params actually took effect, too — this tenant
   accepts and silently ignores several (BU filters on jobs, date+pay-type filters on payroll, date on the
   cancel-log export).

## Orchestration policy (two-tier agent system)

The main agent is the ORCHESTRATOR. Its job is planning, review, and synthesis —
not bulk execution. Follow this division of labor:

1. **Break incoming requests into tasks.** Before touching files, decompose the
   request into concrete, well-scoped tasks with clear success criteria.
2. **Delegate implementation to the right subagent.** All implementation and
   heavy-output work goes to a worker subagent: writing or editing code, running
   command sequences, multi-step file operations, bulk searches across many files,
   data pulls that produce long output. Pass a self-contained brief: exact file
   paths, the change wanted, the conventions that apply, and how to verify.
   - **`worker` (Sonnet) is the default** — routine/mechanical work: file diffs,
     greps, sync checks, dead-code checks, well-specified edits, command runs.
   - **Zero-judgment mechanical sweeps get Haiku**: when a worker task needs no
     interpretation at all (grep/diff/existence checks, byte-compares, log tails),
     pass `model: haiku` on the Agent call — cheaper than Sonnet, same result.
   - **`judgment-worker` (Opus)** is reserved for tasks that genuinely need deeper
     reasoning: deciding whether something is intentional drift vs a bug, weighing
     tradeoffs, ambiguous calls. Default to `worker` unless the task clearly calls
     for judgment-worker.
3. **Keep the main thread for judgment.** The orchestrator handles: clarifying the
   request, choosing the approach, reviewing worker output, cross-checking results
   against the user's intent, and writing the final summary to the user.
4. **No bulk file reads/writes on the main thread.** If answering requires reading
   more than a couple of files or producing large edits, hand it to worker and
   consume its summary instead. Small single-file peeks needed to scope a task are
   fine; sustained execution is not.
5. **Parallelize when tasks are independent** — launch multiple workers in one
   message rather than serially.

Exception: trivial one-shot actions (a single quick command, a one-line edit, a
single status check) may be done directly when delegating would cost more than it saves.
