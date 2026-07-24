# Recover A Codex Session With Legacy `namespace` Fields

## Result

This playbook records two verified recovery outcomes for Codex CLI `0.145.0`
sessions that fail with:

```text
[ObjectParam] [input[257].namespace] [unknown_parameter]
Unknown parameter: 'input[257].namespace'.
```

The number inside `input[...]` varies. The useful signature is the rejected
top-level `namespace` field.

The conservative recovery is to preserve the old session and continue from a
clean handoff. A later GlassAgent recovery proved that the original session ID
can also be restored when all of these conditions are true:

- the rollout is backed up and has no owner process
- inspection finds only the known legacy `exec` and `wait` payloads
- a structured migration removes only those fields
- every JSON line and semantic digest passes before replacement
- a real model turn succeeds after resuming the same ID

Codex officially supports `resume`, `fork`, session archive, and persistent
goals. Direct rollout migration is not a documented public repair interface.
Treat the same-ID procedure below as a narrow, backup-first compatibility
migration, not a general JSONL editing technique.

## Symptom

The session opens and displays its transcript, but a new model turn fails with
HTTP 400:

```text
{
  "type": "error",
  "error": {
    "type": "invalid_request_error",
    "message": "[ObjectParam] [input[257].namespace] [unknown_parameter] Unknown parameter: 'input[257].namespace'."
  },
  "status": 400
}
```

The status line may also show:

```text
Goal blocked (/goal resume)
```

Unrelated MCP login or HTTP warnings can appear at the same time. Confirm the
rollout shape before assuming those warnings caused the failed turn.

## Cause

Affected rollouts contain old response items with a top-level `namespace`
field:

```text
payload.type=custom_tool_call  payload.name=exec  payload.namespace=exec
payload.type=function_call     payload.name=wait  payload.namespace=wait
```

Codex can still render the stored transcript, but the current API rejects those
objects when Codex assembles the next model input. Native `resume` and `fork`
both reproduced the same error before migration.

## Choose A Recovery Level

Use a clean replacement thread when:

- the old thread only needs to be preserved as history
- the rollout contains other unexpected `namespace` shapes
- the rollout is actively changing and cannot be stopped
- semantic validation fails
- preserving the original session ID is not required

Attempt same-ID recovery only when the exact known shapes above are the only
legacy fields and preserving the original transcript is important.

## Same-ID Recovery

Run this from a normal shell, not from the broken Codex TUI.

### 1. Identify The Exact Session

Set task-specific variables:

```bash
SESSION_ID="019f89b7-9775-7a81-84e6-d52a904548ae"
PROJECT_DIR="/home/lachlan/Projects/GlassAgent"
CODEX_STATE="${CODEX_HOME:-$HOME/.codex}"
```

Locate the rollout:

```bash
ROLLOUT="$(
  rg -l --hidden --glob 'rollout-*.jsonl' \
    --fixed-strings "$SESSION_ID" "$CODEX_STATE/sessions" |
  head -n 1
)"
test -n "$ROLLOUT"
printf '%s\n' "$ROLLOUT"
```

Confirm the SQLite row:

```bash
sqlite3 "$CODEX_STATE/state_5.sqlite" \
  "SELECT id, cwd, title, archived FROM threads WHERE id='$SESSION_ID';"
```

Do not rely on a window title alone. Several Codex processes and tmux sessions
may be open at once.

### 2. Map Processes And Tmux Before Touching State

Inventory tmux panes:

```bash
tmux list-panes -a \
  -F '#{session_name}:#{window_index}.#{pane_index} pid=#{pane_pid} cmd=#{pane_current_command} path=#{pane_current_path}'
```

Map live Codex processes to rollout files:

```bash
ps -eo pid,ppid,tty,stat,etime,args |
  rg 'codex( |$)|codex-code-mode-host'

lsof "$ROLLOUT"
```

Stop the owner cleanly before replacement. Never replace a rollout while Codex
still has it open for writing. Re-run `lsof "$ROLLOUT"` and continue only when
it produces no owner row.

### 3. Create A Verifiable Backup

```bash
BACKUP_DIR="$CODEX_STATE/session-recovery-backups/$SESSION_ID/$(date +%Y%m%d-%H%M%S)"
install -d -m 700 "$BACKUP_DIR"

cp --reflink=auto --preserve=mode,timestamps \
  "$ROLLOUT" "$BACKUP_DIR/rollout-original.jsonl"

sqlite3 "$CODEX_STATE/state_5.sqlite" \
  ".backup '$BACKUP_DIR/state_5.sqlite'"

sha256sum "$ROLLOUT" "$BACKUP_DIR/rollout-original.jsonl"
```

The two rollout hashes must match before continuing.

Never commit rollout files, SQLite state, credentials, prompts, or private
handoffs.

### 4. Inspect Without Printing Conversation Content

This reports only object paths and tool metadata:

```bash
jq -r '
  paths(objects) as $path
  | getpath($path) as $object
  | select($object | has("namespace"))
  | [
      ($path | map(tostring) | join(".")),
      ($object.type // ""),
      ($object.name // ""),
      ($object.namespace // "")
    ]
  | @tsv
' "$BACKUP_DIR/rollout-original.jsonl" |
  sort |
  uniq -c |
  sort -nr
```

The validated GlassAgent result was:

```text
14 payload  custom_tool_call  exec  exec
 1 payload  function_call     wait  wait
```

Abort the same-ID path if any other object type, name, namespace, or nested path
appears.

### 5. Build A Structured Repaired Copy

```bash
ORIGINAL="$BACKUP_DIR/rollout-original.jsonl"
REPAIRED="$BACKUP_DIR/rollout-repaired.jsonl"

umask 077
jq -c '
  if (
    (.payload | type) == "object"
    and (.payload | has("namespace"))
    and (
      (
        .payload.type == "custom_tool_call"
        and .payload.name == "exec"
        and .payload.namespace == "exec"
      )
      or
      (
        .payload.type == "function_call"
        and .payload.name == "wait"
        and .payload.namespace == "wait"
      )
    )
  )
  then del(.payload.namespace)
  else .
  end
' "$ORIGINAL" > "$REPAIRED"
```

This uses `jq` as a JSON parser. It does not use regex replacement against raw
conversation text.

### 6. Prove That Nothing Else Changed

Validate JSON, line count, field count, and canonical semantics:

```bash
jq -e -c . "$REPAIRED" >/dev/null

ORIGINAL_LINES="$(wc -l < "$ORIGINAL")"
REPAIRED_LINES="$(wc -l < "$REPAIRED")"
test "$ORIGINAL_LINES" = "$REPAIRED_LINES"

LEGACY_BEFORE="$(
  jq -s '
    [.[] | select(
      (.payload | type) == "object"
      and (.payload | has("namespace"))
    )] | length
  ' "$ORIGINAL"
)"

LEGACY_AFTER="$(
  jq -s '
    [.[] | select(
      (.payload | type) == "object"
      and (.payload | has("namespace"))
    )] | length
  ' "$REPAIRED"
)"

test "$LEGACY_BEFORE" -gt 0
test "$LEGACY_AFTER" = 0
```

Generate two canonical semantic digests. The original stream is normalized
after applying the intended deletion; the repaired stream is normalized as-is:

```bash
EXPECTED_DIGEST="$(
  jq -S -c '
    if (
      (.payload | type) == "object"
      and (.payload | has("namespace"))
      and (
        (
          .payload.type == "custom_tool_call"
          and .payload.name == "exec"
          and .payload.namespace == "exec"
        )
        or
        (
          .payload.type == "function_call"
          and .payload.name == "wait"
          and .payload.namespace == "wait"
        )
      )
    )
    then del(.payload.namespace)
    else .
    end
  ' "$ORIGINAL" | sha256sum | awk '{print $1}'
)"

REPAIRED_DIGEST="$(
  jq -S -c . "$REPAIRED" |
    sha256sum |
    awk '{print $1}'
)"

test "$EXPECTED_DIGEST" = "$REPAIRED_DIGEST"
```

The GlassAgent repair preserved all `30,734` events and removed exactly `15`
legacy fields. The two semantic digests matched.

### 7. Replace The Rollout Atomically

First ensure the live file has not changed since backup:

```bash
ORIGINAL_HASH="$(sha256sum "$ORIGINAL" | awk '{print $1}')"
CURRENT_HASH="$(sha256sum "$ROLLOUT" | awk '{print $1}')"
test "$ORIGINAL_HASH" = "$CURRENT_HASH"
test -z "$(lsof "$ROLLOUT")"
```

Install and validate a temporary file in the same directory, then rename it:

```bash
TEMP_ROLLOUT="${ROLLOUT}.repairing"
test ! -e "$TEMP_ROLLOUT"

install -m 600 "$REPAIRED" "$TEMP_ROLLOUT"
jq -e -c . "$TEMP_ROLLOUT" >/dev/null
test "$(wc -l < "$TEMP_ROLLOUT")" = "$ORIGINAL_LINES"

mv "$TEMP_ROLLOUT" "$ROLLOUT"
```

The final rename is atomic because both paths are in the same directory.

### 8. Resume The Same ID In A Clearly Named Tmux Session

```bash
TMUX_NAME="glassagent-original-019f89b7"

tmux new-session -d \
  -s "$TMUX_NAME" \
  -c "$PROJECT_DIR" \
  "codex -s danger-full-access -a never resume -C '$PROJECT_DIR' '$SESSION_ID'"
```

Attach with:

```bash
tmux attach -t glassagent-original-019f89b7
```

On the validated session, Codex displayed the original GlassAgent transcript
and asked whether to resume its paused persistent goal. Selecting **Leave
paused** proved the correct session loaded without immediately changing files.

### 9. Verify A Real Model Turn

Loading the transcript is not enough; the original failure happened on the next
model request.

Resume the goal with:

```text
/goal resume
```

Then verify that the same session:

- appends new events to the original rollout
- reads the original goal and repository instructions
- can call tools
- does not append another `input[...].namespace` task error
- remains attached to the same rollout file

Process-to-rollout confirmation:

```bash
lsof "$ROLLOUT"
```

The validated GlassAgent session resumed its original objective, read
`AGENTS.md` and the persisted goal file, searched the repository, updated its
plan, and began the pending MIUI Bluetooth fallback work. Its rollout grew from
`30,734` to `30,758` events without another namespace error.

## Validated GlassAgent Record

```text
Session ID: 019f89b7-9775-7a81-84e6-d52a904548ae
Project: /home/lachlan/Projects/GlassAgent
Codex CLI: 0.145.0
Original rollout size: about 147 MB
Original event count: 30,734
Removed fields: 15
Tmux: glassagent-original-019f89b7
Outcome: same ID resumed and completed new tool calls
```

Backup:

```text
~/.codex/session-recovery-backups/019f89b7-9775-7a81-84e6-d52a904548ae/20260725-local-fix/
```

## Conservative Replacement Record

An earlier EchoMind session used the safer replacement-thread path:

```text
Original: 019b31cd-357c-7fa1-ba02-a74e8d3cbf2f
Replacement: 019f9659-d32f-7e33-ad0d-3075c7e33461
Tmux: echomind-codex-repaired
```

That recovery remains valid when the same-ID scope gate is not satisfied:

1. back up the original rollout and state database
2. preserve the original as read-only history
3. write a private handoff outside Git
4. start a clean session in the correct project directory
5. verify a model turn before continuing the task

## Rollback

If the repaired session fails:

1. stop the Codex process that owns the rollout
2. verify `lsof "$ROLLOUT"` is empty
3. install the original backup to a temporary path beside the rollout
4. validate the temporary JSONL
5. atomically rename it over the repaired rollout

Do not restore while Codex has the rollout open.

## Rules Learned

- Match session ID, project directory, process, rollout, and tmux name before
  changing anything.
- Never use a UU Remote handoff to replace a GlassAgent session.
- Preserve a byte-identical backup and SQLite backup before migration.
- Use a structured JSON transform, not raw text substitution.
- Abort on any unexpected `namespace` shape.
- Prove semantic equivalence before replacement.
- A successful UI load is insufficient; require a real model turn and tool call.
- Keep private rollout data and handoffs outside the repository.
