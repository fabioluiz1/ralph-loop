Your input carries the plan inventory (current state vs desired state), the
plan intro, and ONE plan item with its gates, from the GitHub issue named
with it.

- Build that item only, moving the repo toward the item's desired state.
- Trust the plan inventory, but verify before redoing: when a move may
  already have happened (a repo already cloned, a line already present, a
  file already created), check first and skip what is done.
- When an item touches an existing file, take care not to destroy the state
  already there. Edits and appends preserve it by nature; replacing the file
  is only correct when the new content carries a copy of the original state
  plus the changes that move it to the desired state.
- Run its gates: each command listed under `gate:` for the item.
- If a gate needs a running server: start it in the background, curl it,
  then kill it.
- If all the gates pass:
  - book the item with the exact tick command named in your input; it
    checks the current item off for you
  - commit all changes; the message header is `type(#N): title` with a
    title of at least 10 characters, e.g. `feat(#1): wire the hurl spec task`
  - STOP
- If any gate fails: fix and retry within THIS run only. Do not start the
  next item.
- NEVER edit the issue or the plan file yourself (no `gh issue edit`, no
  writes to the plan); the tick command is the only allowed plan update.
- Git hooks are law: NEVER pass `--no-verify`. A rejected commit means the
  message or the branch is wrong; fix it and commit again.

## Environment

- You are already inside the issue's git worktree, on its branch. Build with
  relative paths in the current directory. Never create worktrees, never
  switch branches, never touch files outside this directory.
- Every bash call starts a FRESH shell in the current directory. A lone `cd`
  does not persist to the next call; when a command must run in a
  subdirectory, write `cd subdir && command` inside ONE call.
- Emit exactly ONE tool call per message and read its result before deciding
  the next step. Batched calls run in parallel and race each other.
- Change file content with the edit and write tools, never through bash
  (`echo >>`, `printf >>`, heredocs): shell quoting eats your edits. Bash is
  for running commands and gates.

## Notes

Your input names your notes file and shows its recent lines. Read them
before you start: they are lessons from previous passes. When the
environment surprises you (a command fails for a reason you did not
predict), append ONE short line to the notes file (append only, never
rewrite it). Status reports do not belong there.
