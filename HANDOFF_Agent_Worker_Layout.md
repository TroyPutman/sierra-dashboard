# HANDOFF — Two-Tier Agent / Worker Layout (portable setup)

A self-contained recipe to reproduce the cost-optimized orchestrator/worker agent
setup on any account/machine. This is the Anthropic "expensive model plans, cheaper
models build" pattern. Nothing here is project-specific — swap the one "project
conventions" bullet for your own project's rules.

## THE IDEA (30 seconds)

- The **main agent = orchestrator** (whatever model you run the session on). It
  plans, reviews, and synthesizes — it does NOT do bulk execution.
- It **delegates the actual work to cheaper "worker" subagents** and consumes their
  short summaries.
- Cheaper models do most of the tokens → most of the cost is billed at the low rate.
  (Anthropic's BrowseComp: a hybrid lead+worker setup held ~96% of top-tier quality
  at ~46% of the cost.)

Tiers used here:

| Tier | Model | Effort | For |
|------|-------|--------|-----|
| Orchestrator (main loop) | **Fable 5** (pinned via settings.json — see Step 0) | high | planning, review, synthesis, judgment, the final user reply |
| `worker` | Sonnet | low | the DEFAULT delegate — routine/mechanical execution |
| `worker` w/ `model: haiku` on the call | Haiku | low | zero-judgment sweeps (grep/diff/existence/byte checks, log tails) |
| `judgment-worker` | Opus | high (default) | ambiguous / high-stakes calls (is-this-a-bug-or-intentional, tradeoffs) |

The orchestrator model is NOT set by the agent files — it's the session model. Pin
it so every session in the workspace starts on Fable (Step 0) instead of relying on
whoever remembers to pick it.

## STEP 0 — Pin the orchestrator (main brain) to Fable

Add `model` to the workspace's `.claude/settings.json` (project settings override
the global default, so this scopes Fable to this workspace only — other projects are
unaffected):

```json
{
  "model": "claude-fable-5"
}
```

Merge it into the existing `settings.json` if the file already has keys (permissions,
theme, plugins, etc.) — just add the `"model"` line, don't overwrite the rest. Now
any session opened in this workspace uses Fable 5 as the orchestrator by default; the
worker tiers below override to their own (cheaper) models per delegation.

## STEP 1 — Create the two agent files

Put these in `.claude/agents/` — either in your project (`<project>/.claude/agents/`,
applies to that project) or your home dir (`~/.claude/agents/`, applies everywhere).

### File: `.claude/agents/worker.md`
```markdown
---
name: worker
description: Executes implementation tasks — writing code, running commands, multi-step file work. Use for any task requiring sustained execution rather than planning.
tools: Read, Write, Edit, Bash, Grep, Glob
model: sonnet
effort: low
---

You are the implementation worker for this project. You receive a well-scoped task
from the orchestrating agent and you execute it directly — write the code, run the
commands, edit the files, verify the result.

Rules:
- Do the work yourself, fully. Don't plan out loud, don't ask for confirmation —
  the orchestrator already made the scoping decisions before delegating to you.
- Verify what you build: run the code, check exit codes, re-read edited sections
  when correctness matters. If something fails, fix it and retry before reporting.
- Respect this project's conventions (they are in CLAUDE.md and any memory files).
  <<REPLACE THIS with 2–4 of your project's hard rules so the worker doesn't
  violate them — e.g. "never edit generated files by hand", "run `npm test` before
  reporting done", coding-style rules, etc.>>
- Your final message is your ONLY output the orchestrator sees. Make it a concise
  summary: what you did, what you verified, exact file paths touched, and anything
  that failed or needs a follow-up decision. Do NOT return full file contents,
  full command transcripts, or step-by-step narration — just the outcome.
```

### File: `.claude/agents/judgment-worker.md`
```markdown
---
name: judgment-worker
description: Executes tasks that need real judgment calls — deciding whether drift is intentional vs a bug, weighing tradeoffs, resolving ambiguous or high-stakes calls. NOT for routine mechanical work (diffs, greps, sync checks, bulk edits) — use `worker` for those. Reach for this only when the task genuinely requires deeper reasoning.
tools: Read, Write, Edit, Bash, Grep, Glob
model: opus
---

You are the judgment worker for this project. You receive tasks from the
orchestrating agent that require genuine reasoning — ambiguous calls, tradeoff
decisions, distinguishing intentional design from accidental drift — and you
execute them directly: investigate, decide, and act (or recommend, if the brief
asks for a recommendation rather than a change).

Rules:
- Do the work yourself, fully. Don't plan out loud, don't ask for confirmation —
  the orchestrator already made the scoping decisions before delegating to you.
- When the task hinges on a judgment call, state your reasoning and confidence
  explicitly in your summary — the orchestrator needs to know why you decided,
  not just what.
- Verify what you build: run the code, check exit codes, re-read edited sections
  when correctness matters. If something fails, fix it and retry before reporting.
- Respect this project's conventions (they are in CLAUDE.md and any memory files).
  <<REPLACE with your project's hard rules, same as the worker.>>
- Your final message is your ONLY output the orchestrator sees. Make it a concise
  summary: what you decided and why, what you did, what you verified, exact file
  paths touched, and anything that failed or needs a follow-up decision. Do NOT
  return full file contents, full command transcripts, or step-by-step narration —
  just the outcome.
```

Notes on the frontmatter:
- `model:` accepts `haiku` | `sonnet` | `opus` (and other configured aliases). It
  overrides the model for that subagent regardless of the session model.
- `effort:` is the reasoning effort (`low` | `medium` | `high` | `xhigh` | `max`).
  `low` on the worker is safe because it only ever gets fully-specified tasks;
  leave `judgment-worker` at its default so hard calls still think deeply.
- `tools:` restricts what the subagent can do — the set above (Read/Write/Edit/
  Bash/Grep/Glob) is right for a general code/file worker. Trim if you want a
  read-only researcher.

## STEP 2 — Add the orchestration policy to CLAUDE.md

Paste this section into your project's `CLAUDE.md` (or `~/.claude/CLAUDE.md` for
global). It's what tells the main agent to actually delegate instead of doing
everything itself.

```markdown
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
single status check) may be done directly when delegating would cost more than it
saves.
```

## STEP 3 — How to invoke (what the orchestrator actually does)

- Delegate with the **Agent tool**, setting `subagent_type` to the agent name:
  `subagent_type: "worker"` or `subagent_type: "judgment-worker"`.
- For a zero-judgment sweep, use `worker` but override the model on the call:
  `subagent_type: "worker", model: "haiku"`.
- **Parallelize**: put multiple Agent calls in ONE message so they run
  concurrently (independent tasks only).
- **Brief well**: every delegation must be self-contained — exact paths, the change
  wanted, the conventions that apply, and how to verify. The worker can't see your
  conversation; it only gets the brief.
- **Consume the summary**, don't re-do the work. The worker's final message is the
  only thing that returns to the orchestrator.

## GOTCHAS / TIPS

- **Takes effect at spawn.** Model/effort/policy changes apply to NEWLY spawned
  agents; you don't restart anything, but an already-running agent keeps its
  original settings.
- **Don't over-delegate trivia.** A single one-line edit or status check is cheaper
  done inline than shipped to a subagent (the Exception clause covers this).
- **Match the tier to the task, honestly.** Most work is `worker`. Reach for
  `judgment-worker` only when there's a real "which is correct / is this a bug"
  decision — using Opus for mechanical work just burns money for no quality gain.
- **The orchestrator is still the expensive part.** Long interactive sessions cost
  the most (every turn carries the whole conversation). Start fresh sessions per
  distinct task; keep the marathon threads for genuine build days.
- **Verify, then trust.** Have workers verify their own output (run it, check exit
  codes) and report what they verified — then the orchestrator reviews the summary
  rather than re-running everything.

## ONE-LINE CHECKLIST TO REPLICATE
1. Pin the orchestrator: add `"model": "claude-fable-5"` to `.claude/settings.json`.
2. Create `.claude/agents/worker.md` (model: sonnet, effort: low).
3. Create `.claude/agents/judgment-worker.md` (model: opus).
4. Paste the Orchestration policy into `CLAUDE.md`.
5. Customize the "project conventions" bullet in both agent files.
6. Done — delegate via the Agent tool with `subagent_type`, override `model: haiku`
   for pure-mechanical sweeps.
