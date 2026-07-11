# ralph-loop

A [Ralph loop](https://ghuntley.com/ralph/): the simplest autonomous agent there is. A shell
`while` loop drives [Pi](https://pi.dev) against a local Ollama model, one fresh pass at a time.
The plan lives in a GitHub issue, not on disk; each pass builds ONE plan item, runs that item's
gates, and books its own work back to the issue.

## The target: RealWorld

What the loop builds here is **Conduit**, a Medium-style blogging app defined by
[RealWorld](https://github.com/realworld-apps/realworld): one shared API spec that hundreds of
stacks have implemented, plus a ready-made test suite any implementation must pass. That suite
is the gate: a judge nobody in the loop authored.

- **Spec + hurl suite**: [realworld-apps/realworld](https://github.com/realworld-apps/realworld),
  the API spec with runnable [Hurl](https://hurl.dev) tests under `specs/api/hurl/`
- **Identity service reference (Python + FastAPI)**:
  [nsidnev/fastapi-realworld-example-app](https://github.com/nsidnev/fastapi-realworld-example-app)
- **Content service reference (TypeScript + NestJS)**:
  [lujakob/nestjs-realworld-example-app](https://github.com/lujakob/nestjs-realworld-example-app)
- **Frontend reference (Vite + React)**:
  [romansndlr/react-vite-realworld-example-app](https://github.com/romansndlr/react-vite-realworld-example-app)

The references are yardsticks, not sources: the loop's model writes its own implementation
against the spec, and the human compares the generated code to how each community reference
solved the same problem.

## The pieces

The three protagonists:

- `ralph/pure-loop.sh`: the pure loop; one plan item per fresh pi pass, pinned to the local model
- `ralph/PROMPT.md`: the fixed instruction every fresh pass reads
- the plan: a GitHub issue whose body is a checklist, each item carrying its own gates

And the companion scripts around them:

- `ralph/run.sh`: the launcher; backgrounds the loop, logs its raw stream, attaches the viewer
- `ralph/prepare-loop.sh`: everything a pass needs; resolves the plan, the worktree, the prompt
- `ralph/guard.sh`: the watchdog; kills a pass that spills to CPU (halts the loop) or outlives
  its `PASS_TIMEOUT` budget (default 1800s; the next pass retries fresh)
- `ralph/plan.sh`: publishes the plan inventory back to the source as a marked comment
  (`<!-- ralph:plan -->`), or as `<source>-plan.md` for a local plan file
- `ralph/PLAN-PROMPT.md`: the plan pass instruction; inventory only, build nothing
- `ralph/tick.sh`: checks the finished item off at the plan source once its gates pass
- `ralph/watch.sh`: the viewer; tails a run log and renders it live, re-attach or replay anytime
- `ralph/telemetry.py`: the observer; ingests run logs into `ralph/telemetry/telemetry.db` (SQLite)
  for token/time aggregation, batch or live

## Telemetry: observe, never touch

The loop is never instrumented. It writes its raw NDJSON log and nothing else; telemetry is a
separate process that tails that log read-only and materializes `runs -> passes -> events`
into SQLite, with `pass_stats` / `run_stats` / `branch_stats` views for aggregation. Killing
the observer never affects the run; relaunching it resumes from a per-log byte offset.

```bash
ralph/telemetry.py                  # ingest every log under ralph/logs once
ralph/telemetry.py --follow <log>   # tail a live run, ingesting in real time

sqlite3 -header -column ralph/telemetry/telemetry.db \
  "SELECT n, model, seconds, tokens, tool_calls, errors FROM pass_stats"
```

The log stays the whole truth (event content in the DB is capped at 2000 chars, pointing back
to the log for full inspection), and the database is derived: delete it and rebuild anytime.

## Plan mode: the plan inventory

No item is built before the inventory exists. A source without a published plan inventory turns the
first pass into the **plan pass**: the model inspects the repo and writes, per checklist item,
the inventory of **current state vs desired state** plus the moves that close the gap, flagging
whatever the plan assumes but does not say (files that already carry content, steps already
done, contradictions). The inventory lands in the worktree as `ralph/artifacts.md` and is published
to the source by `ralph/plan.sh`; every later pass reads it from there and orients its moves
toward the desired state. Ticks never touch it: the checklist in the original source stays the
only loop control.

## Where things live

- `.worktrees/<branch>/`: each plan grinds in its own git worktree, on a branch pi names once
  from the plan (`type-N-kebab-title`)
- `.worktrees/<branch>/.ralph/`: that worktree's loop state (source marker, stuck counter,
  pass prompt); dies with the worktree
- `ralph/logs/<branch>/`: one NDJSON log and one pid file per run; outlives the worktree
- `ralph/telemetry/telemetry.db`: the derived SQLite database; lives with the root harness,
  never inside a disposable worktree
- `.worktrees/<branch>/ralph/run/NOTES.md`: append-only pass-to-pass memory; the model reads
  it every pass and adds a line when the environment surprises it

## Prerequisites

- [Pi](https://pi.dev) (`pi`), with the Ollama provider configured
- [Ollama](https://ollama.com) serving locally, with the model pulled: `ollama pull qwen3:8b`
- [GitHub CLI](https://cli.github.com) (`gh`), authenticated against the repo that holds the plan

## Write the plan as an issue

The body is a flat markdown checklist. Every item states one task and lists the commands that
prove it done, its **gates**:

```text
- [ ] services/identity boots a FastAPI app on :8001 with GET /health -> {"status":"ok"}
  - gate: `curl -s localhost:8001/health` prints {"status":"ok"}
```

Rules the driver depends on:

- items start at column 0 with `- [ ]`; done items are `- [x]`
- everything indented under an item (the `- gate:` lines) belongs to that item
- a gate is a runnable command with an observable pass condition

## Run the loop

```bash
ralph/run.sh <issue-url> [max-passes]

# example: grind issue #1, default cap of 10 passes
ralph/run.sh https://github.com/fabioluiz1/ralph-loop/issues/1

# escalate the model without touching the loop
MODEL=qwen3-coder:30b ralph/run.sh https://github.com/fabioluiz1/ralph-loop/issues/1 20
```

Each pass:

1. reads the plan from the issue body via `gh`
2. exits green if no `- [ ]` items remain
3. with no plan inventory published yet, becomes the plan pass: inventory, publish, stop
4. slices out the top unchecked item plus its gates
5. feeds `ralph/PROMPT.md` + the plan inventory + that single item to a fresh `pi` pass,
   pinned to the local model, under `ralph/guard.sh`
6. the model builds the item inside the plan's worktree, runs its gates, and on green ticks
   the box via `ralph/tick.sh` and commits

The loop stops when the plan is complete, when the pass cap hits with items still unchecked
(exit 1: hand it back to a human), or the moment a model spills to the CPU (exit 3: this
machine cannot run that model honestly; escalating onto a spilled model only grinds harder).
If the same item survives `ESCALATE_AFTER` consecutive passes (default 2), the next pass runs
on `ESCALATION_MODEL` (default `qwen3-coder:30b`), then hands back to the base model.

The run and the viewer share only the log file:

- Ctrl-C detaches the viewer; the loop grinds on unwatched
- `ralph/watch.sh <log>` re-attaches (or replays a finished run)
- `kill -- -<pid>` (printed at launch) stops the run itself

## Warning

The model runs with bash access, unattended. Point the loop only at a repo you can afford to
reset, never at a machine or checkout holding credentials that matter.
