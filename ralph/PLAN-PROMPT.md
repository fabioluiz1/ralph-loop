Your input carries a full plan (intro and checklist) from its source. This
pass builds NOTHING. It is the plan pass: build the plan inventory, publish it.

- For EVERY checklist item, inspect the repository as it actually is and
  write the inventory:
  - current state: what already exists (files, directories, config, tools)
  - desired state: what the item's gates demand
  - the moves that close the gap, each oriented only toward the desired state
- Call out anything the plan assumes but does not say: files that already
  carry content, steps already done, contradictions, missing information.
- When an item touches an existing file, the desired state INCLUDES the
  state already there surviving. Plan the move as an append or an edit; a
  replacement is only acceptable when it carries the original content plus
  the delta. Quote the lines that must survive.
- Write the inventory to ralph/artifacts.md with the write tool.
- Publish it with the exact plan.sh command named in your input.
- Do not build, do not commit, do not tick. When the publish command
  succeeds, STOP.

## Environment

- You are already inside the issue's git worktree, on its branch. Inspect
  with relative paths in the current directory. Never create worktrees,
  never switch branches, never touch files outside this directory.
- Every bash call starts a FRESH shell in the current directory. A lone `cd`
  does not persist to the next call.
- Emit exactly ONE tool call per message and read its result before deciding
  the next step.
- Write file content with the write tool, never through bash (`echo >>`,
  heredocs): shell quoting eats your edits. Bash is for inspecting.
