# Codex session recovery for broken resume after CLI upgrade

This note covers a real failure on `2026-07-25` for session:

- `019b31cd-357c-7fa1-ba02-a74e8d3cbf2f`

## Quick match

Use this recovery flow when `codex resume` opens but the first model turn fails
with output like:

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

and the UI also shows:

```text
Goal blocked (/goal resume)
```

The exact `input[257]` index is not important. Any
`Unknown parameter: 'input[...].namespace'` variant is the same class of
failure.

## One-screen operator runbook

Do this from a normal shell, not from the broken resumed thread:

```bash
SKILL_DIR="${CODEX_HOME:-$HOME/.codex}/skills/codex-session-recovery"
RECOVERY="$SKILL_DIR/scripts/codex_session_recovery.py"
SESSION_ID="019b31cd-357c-7fa1-ba02-a74e8d3cbf2f"  # replace with the broken id

python3 "$RECOVERY" --json doctor
python3 "$RECOVERY" --json inspect "$SESSION_ID"
python3 "$RECOVERY" --json recover "$SESSION_ID" --dry-run
python3 "$RECOVERY" --json recover "$SESSION_ID" --yes
python3 "$RECOVERY" --json probe "$SESSION_ID"
```

Then:

1. keep the original broken thread as archive only
2. write or reuse a private handoff for the unfinished work
3. start a clean replacement Codex thread from that handoff
4. continue the blocked task in the replacement thread

Do not keep retrying `/goal resume` or `promote staged 4.34` inside the broken
thread after this exact API-shape error appears. The practical fix is thread
replacement, not another resume attempt.

## Symptom

`codex resume` opened the shell UI but failed during startup with:

- `Unknown parameter: 'input[308].namespace'`
- `Goal blocked (/goal resume)`

At the same time, Codex also showed MCP warnings for:

- `biorender` not logged in
- `openaiDeveloperDocs` failed with HTTP 403

Those MCP warnings were not the root cause of the broken resume.

## Real cause

The old rollout contained legacy tool payloads with a top-level `namespace` field, for example:

- `name:"exec", namespace:"exec"`
- `name:"wait", namespace:"wait"`

Current Codex CLI `0.145.0` / current API validation rejected that old payload shape during resume.

The failure is in old serialized thread payloads, not in the current task
content. A later command like `promote staged 4.34` can be perfectly valid and
still fail because resume never reaches a usable live thread state.

## Safe recovery result

Used the bundled recovery skill/tool:

- `~/.codex/skills/codex-session-recovery/scripts/codex_session_recovery.py`

Steps:

1. confirmed protocol compatibility with `doctor`
2. inspected the exact thread UUID
3. verified the rollout owner process
4. stopped the stuck resume process cleanly
5. ran `recover --dry-run`
6. ran `recover --yes`
7. compaction itself failed with a non-retryable turn error, but:
   - backup succeeded
   - append-only verification succeeded
   - the interrupted compaction was cleaned up safely
8. ran `probe` and confirmed the thread could be loaded without adding a model turn
9. a real resumed model turn still failed on the legacy `namespace` payload
10. preserved the original thread as an append-only private archive
11. wrote a curated private handoff outside Git
12. started a clean replacement thread from that handoff and verified its goal was active

## Backup created

Private backup location:

- `~/.codex/session-recovery-backups/019b31cd-357c-7fa1-ba02-a74e8d3cbf2f/20260725-064233/`

Key files:

- `rollout-original.jsonl.zst`
- `manifest.json`

## Practical status after recovery

The original thread can be loaded but cannot safely complete new model turns.
Do not edit its rollout JSONL or the shared Codex SQLite databases to remove the
legacy fields.

Treat that thread as read-only evidence after backup and probe succeed.

The working replacement is:

- session: `019f9659-d32f-7e33-ad0d-3075c7e33461`
- tmux: `echomind-codex-repaired`
- state: persistent EchoMind objective active and pursuing the recovered plan

The private handoff is stored under:

- `~/.codex/session-handoffs/019b31cd-357c-7fa1-ba02-a74e8d3cbf2f/`

This gives the practical result of a repaired session without corrupting the
shared Codex state database.

## MCP warning cleanup

The warnings were separate from the broken session:

- removed the `openaiDeveloperDocs` MCP entry after confirming its endpoint
  returned HTTP 403 from this network
- restarted the local BioRender proxy
- refreshed the private BioRender OAuth token through the repository's
  dedicated browser/login workflow
- verified authenticated MCP `initialize` and `tools/list`
- confirmed five BioRender tools were available

The clean replacement Codex session then started without either warning.

## Commands used

```bash
SKILL_DIR="${CODEX_HOME:-$HOME/.codex}/skills/codex-session-recovery"
RECOVERY="$SKILL_DIR/scripts/codex_session_recovery.py"

python3 "$RECOVERY" --json doctor
python3 "$RECOVERY" --json inspect 019b31cd-357c-7fa1-ba02-a74e8d3cbf2f
python3 "$RECOVERY" --json recover 019b31cd-357c-7fa1-ba02-a74e8d3cbf2f --dry-run
python3 "$RECOVERY" --json recover 019b31cd-357c-7fa1-ba02-a74e8d3cbf2f --yes
python3 "$RECOVERY" --json probe 019b31cd-357c-7fa1-ba02-a74e8d3cbf2f
```

## What not to do

- do not hand-edit `~/.codex/sessions/.../rollout-*.jsonl`
- do not hand-edit `~/.codex/state_5.sqlite`
- do not assume MCP warnings are the root cause
- do not keep retrying the same broken resumed session after the
  `input[...].namespace` validation error is confirmed
- do not promote staged work from the broken thread; promote it only from the
  clean replacement thread after the handoff has been loaded

## tmux note

Used a dedicated tmux session for the verification step:

- `codex-session-fix`

The active replacement thread runs in:

- `echomind-codex-repaired`

Attach with:

```bash
tmux attach -t echomind-codex-repaired
```
