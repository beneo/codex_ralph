#!/bin/bash

# codex-ralph Stop Hook (forked from ralph-wiggum)
# = ralph-wiggum loop + Codex review gate
#
# Phases:
#   implementing — Claude works on task (ralph-wiggum behavior)
#   reviewing    — Codex review pending or completed
#   fixing       — Claude fixes Codex findings

set -euo pipefail

# Debug log — traces every decision (defined before trap so trap can use it)
DBGLOG=".claude/codex-ralph-hook.log"
dbg() { echo "[$(date +%H:%M:%S)] $*" >> "$DBGLOG" 2>/dev/null || true; }

trap 'echo "[$(date +%H:%M:%S)] ERROR at line $LINENO (exit $?)" >> "$DBGLOG" 2>/dev/null; exit 0' ERR

HOOK_INPUT=$(cat)

# cd to the project directory (hook may run from a different CWD when registered in settings.json)
HOOK_CWD=$(echo "$HOOK_INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "")
if [[ -n "$HOOK_CWD" ]] && [[ -d "$HOOK_CWD" ]]; then
  cd "$HOOK_CWD"
fi

dbg "=== HOOK START ==="
dbg "CWD: $(pwd)"
dbg "INPUT: $(echo "$HOOK_INPUT" | head -c 200)"

RALPH_STATE_FILE=".claude/codex-ralph.local.md"

if [[ ! -f "$RALPH_STATE_FILE" ]]; then
  dbg "EXIT: no state file"
  exit 0
fi
dbg "State file exists"

# ── Parse frontmatter ───────────────────────────────────────
FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$RALPH_STATE_FILE")
ITERATION=$(echo "$FRONTMATTER" | grep '^iteration:' | sed 's/iteration: *//')
MAX_ITERATIONS=$(echo "$FRONTMATTER" | grep '^max_iterations:' | sed 's/max_iterations: *//')
COMPLETION_PROMISE=$(echo "$FRONTMATTER" | grep '^completion_promise:' | sed 's/completion_promise: *//' | sed 's/^"\(.*\)"$/\1/')
PHASE=$(echo "$FRONTMATTER" | grep '^phase:' | sed 's/phase: *//')
REVIEW_ID=$(echo "$FRONTMATTER" | grep '^review_id:' | sed 's/review_id: *//')

[[ -z "$PHASE" ]] && PHASE="implementing"
[[ -z "$REVIEW_ID" ]] && REVIEW_ID="$(date +%Y%m%d-%H%M%S)"

# ── Validate ────────────────────────────────────────────────
if [[ ! "$ITERATION" =~ ^[0-9]+$ ]]; then
  echo "⚠️  codex-ralph: State file corrupted (iteration='$ITERATION')" >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

if [[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
  echo "⚠️  codex-ralph: State file corrupted (max_iterations='$MAX_ITERATIONS')" >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $ITERATION -ge $MAX_ITERATIONS ]]; then
  echo "🛑 codex-ralph: Max iterations ($MAX_ITERATIONS) reached."
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# ── Helpers ─────────────────────────────────────────────────
REVIEW_FILE="reviews/codex-ralph-${REVIEW_ID}.md"
RUNNER_FILE=".claude/codex-ralph-run-${REVIEW_ID}.sh"

transition_phase() {
  local new_phase="$1"
  local TEMP="${RALPH_STATE_FILE}.tmp.$$"
  if grep -q '^phase:' "$RALPH_STATE_FILE"; then
    sed "s/^phase: .*/phase: $new_phase/" "$RALPH_STATE_FILE" > "$TEMP"
  else
    # Add phase field after iteration line
    sed "/^iteration:/a\\
phase: $new_phase" "$RALPH_STATE_FILE" > "$TEMP"
  fi
  mv "$TEMP" "$RALPH_STATE_FILE"
}

check_approval() {
  local f="$1"
  [[ ! -s "$f" ]] && return 1
  if grep -qi "APPROVED" "$f" && ! grep -qi "NEEDS_FIXES" "$f"; then return 0; fi
  if grep -qiE 'looks good to me|no issues found|\bLGTM\b' "$f"; then return 0; fi
  local p1 p2
  p1=$(grep -ciE '\[P1\]' "$f" 2>/dev/null || echo "0")
  p2=$(grep -ciE '\[P2\]' "$f" 2>/dev/null || echo "0")
  [[ "$p1" = "0" ]] && [[ "$p2" = "0" ]] && return 0
  return 1
}

sanitize_review() {
  grep -vE '^\s*(system|assistant|user)\s*:|^\s*<\s*(system|prompt|instruction)|ignore\s+(previous|above)\s+instructions|you\s+are\s+now|forget\s+(your|all)\s+(instructions|rules)' "$1" 2>/dev/null || cat "$1"
}

emit_block() {
  local reason="$1" msg="$2"
  jq -n --arg r "$reason" --arg s "$msg" '{decision:"block", reason:$r, systemMessage:$s}' 2>/dev/null \
    || printf '{"decision":"block","reason":"%s","systemMessage":"%s"}\n' "$(echo "$reason" | head -1)" "$msg"
}

# ═══════════════════════════════════════════════════════════
# PHASE: reviewing — Codex review completed or pending
# ═══════════════════════════════════════════════════════════
if [[ "$PHASE" == "reviewing" ]]; then

  if [[ ! -f "$REVIEW_FILE" ]]; then
    # Review not yet run — tell Claude to run it
    emit_block \
      "Codex review required. Run the review script (use 600000ms timeout):

\`\`\`
bash $RUNNER_FILE
\`\`\`

Then read $REVIEW_FILE and address any P1/P2 findings.
Use your own judgment — fix genuine issues, note disagreements." \
      "🔍 codex-ralph: run Codex review"
    exit 0
  fi

  # Review file exists — check verdict
  if check_approval "$REVIEW_FILE"; then
    dbg "EXIT: APPROVED"; echo "✅ codex-ralph: Codex APPROVED"
    rm -f "$RALPH_STATE_FILE" "$RUNNER_FILE"
    exit 0
  fi

  # NEEDS_FIXES — extract findings, transition to fixing
  FINDINGS=$(sanitize_review "$REVIEW_FILE" | grep -E '\[P[12]\]' | head -15 || echo "See $REVIEW_FILE")

  transition_phase "fixing"

  emit_block \
    "Codex found P1/P2 issues. Fix them:

$FINDINGS

Full review: $REVIEW_FILE
After fixing, continue your task normally." \
    "🔄 codex-ralph: fix Codex findings"
  exit 0
fi

# ═══════════════════════════════════════════════════════════
# PHASE: fixing — Claude fixed, go back to implementing
# ═══════════════════════════════════════════════════════════
if [[ "$PHASE" == "fixing" ]]; then
  # Claude finished fixing → back to implementing
  # Remove old review artifacts so next review is fresh
  rm -f "$REVIEW_FILE" "$RUNNER_FILE"
  transition_phase "implementing"
  # Fall through to implementing logic below
fi

# ═══════════════════════════════════════════════════════════
# PHASE: implementing — Original ralph-wiggum behavior + Codex gate
# ═══════════════════════════════════════════════════════════

# Get transcript
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path')

if [[ ! -f "$TRANSCRIPT_PATH" ]]; then
  dbg "EXIT: transcript not found"; echo "⚠️  codex-ralph: Transcript not found" >&2
  exit 0
fi

if ! grep -q '"role":"assistant"' "$TRANSCRIPT_PATH"; then
  dbg "EXIT: no assistant messages"; echo "⚠️  codex-ralph: No assistant messages in transcript" >&2
  exit 0
fi

LAST_LINE=$(grep '"role":"assistant"' "$TRANSCRIPT_PATH" | tail -1)
if [[ -z "$LAST_LINE" ]]; then
  exit 0
fi

set +e
LAST_OUTPUT=$(echo "$LAST_LINE" | jq -r '.message.content | map(select(.type == "text")) | map(.text) | join("\n")' 2>&1)
JQ_EXIT=$?
set -e

if [[ $JQ_EXIT -ne 0 ]] || [[ -z "$LAST_OUTPUT" ]]; then
  dbg "EXIT: jq empty or failed (exit=$JQ_EXIT) — keeping state file, approving exit"
  # DON'T delete state file — this may be an early Stop event before Claude finished working
  exit 0
fi

# ── Check for completion promise ────────────────────────────
if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
  # Re-strip quotes every time (phase transitions may re-parse YAML with different quoting)
  COMPLETION_PROMISE=$(echo "$COMPLETION_PROMISE" | sed 's/^"//;s/"$//')

  PROMISE_TEXT=$(echo "$LAST_OUTPUT" | perl -0777 -pe 's/.*?<promise>(.*?)<\/promise>.*/$1/s; s/^\s+|\s+$//g; s/\s+/ /g' 2>/dev/null || echo "")

  if [[ -n "$PROMISE_TEXT" ]] && [[ "$PROMISE_TEXT" = "$COMPLETION_PROMISE" ]]; then
    # Promise detected! But DON'T release yet — run Codex review first
    dbg "PROMISE DETECTED: $PROMISE_TEXT"; echo "🔍 codex-ralph: Promise detected, running Codex review..."

    dbg "Checking codex CLI..."
    # Check codex available
    if ! command -v codex &>/dev/null; then
      emit_block \
        "Codex CLI is not installed. Install it to enable review: npm install -g @openai/codex" \
        "⚠️ codex-ralph: codex CLI not found"
      exit 0
    fi

    # Get base SHA for scoped review
    BASE_SHA=$(echo "$FRONTMATTER" | grep '^base_sha:' | sed 's/base_sha: *//')

    # Build review prompt
    REVIEW_PROMPT="Review all code changes in this repository."
    if [[ -n "$BASE_SHA" ]]; then
      REVIEW_PROMPT="Review changes since commit $BASE_SHA. Run: git diff ${BASE_SHA}..HEAD"
    fi
    REVIEW_PROMPT="$REVIEW_PROMPT

For each issue: [P1] Critical, [P2] Important, [P3] Minor, [P4] Nitpick.
Output: Summary, Findings, Verdict (APPROVED or NEEDS_FIXES).
Goals: 1) Task goal achieved? 2) Correct and complete? 3) Bugs/errors/gaps?"

    dbg "Creating review files..."
    mkdir -p reviews
    printf '%s' "$REVIEW_PROMPT" > ".claude/codex-ralph-prompt-${REVIEW_ID}.txt"
    dbg "Prompt written, generating runner..."

    # Generate runner script
    cat > "$RUNNER_FILE" << RUNNER_EOF
#!/usr/bin/env bash
set -euo pipefail
echo "Running Codex review (gpt-5.3-codex / xhigh)..."
echo "This may take 5-15 minutes."
echo "─────────────────────────────────────────────────"
RESULT=\$(codex exec \\
  -m gpt-5.3-codex \\
  --config model_reasoning_effort=xhigh \\
  --sandbox read-only \\
  --full-auto \\
  --skip-git-repo-check \\
  "\$(cat .claude/codex-ralph-prompt-${REVIEW_ID}.txt)" 2>/dev/null) || {
    echo "Codex failed (exit \$?)" >&2
    mkdir -p reviews
    printf '## Verdict\nNEEDS_FIXES — Codex execution failed.\n' > ${REVIEW_FILE}
    cat ${REVIEW_FILE}
    exit 0
  }
mkdir -p reviews
printf '%s' "\$RESULT" > ${REVIEW_FILE}
echo "\$RESULT"
echo "─────────────────────────────────────────────────"
echo "Review saved to ${REVIEW_FILE}"
RUNNER_EOF
    chmod +x "$RUNNER_FILE"

    dbg "Runner script created, transitioning phase..."
    transition_phase "reviewing"
    dbg "Phase transitioned, emitting block..."

    emit_block \
      "Codex review required. Run the review script (use 600000ms timeout):

\`\`\`
bash $RUNNER_FILE
\`\`\`

Then read $REVIEW_FILE and address any P1/P2 findings.
Use your own judgment — fix genuine issues, note disagreements." \
      "🔍 codex-ralph: Codex review"
    exit 0
  fi
fi

# ── Not complete — continue loop (original ralph-wiggum) ────
NEXT_ITERATION=$((ITERATION + 1))

PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$RALPH_STATE_FILE")

if [[ -z "$PROMPT_TEXT" ]]; then
  echo "⚠️  codex-ralph: No prompt text found" >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

TEMP_FILE="${RALPH_STATE_FILE}.tmp.$$"
sed "s/^iteration: .*/iteration: $NEXT_ITERATION/" "$RALPH_STATE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$RALPH_STATE_FILE"

if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
  SYSTEM_MSG="🔄 codex-ralph iteration $NEXT_ITERATION | To stop: output <promise>$COMPLETION_PROMISE</promise> (ONLY when TRUE)"
else
  SYSTEM_MSG="🔄 codex-ralph iteration $NEXT_ITERATION"
fi

jq -n \
  --arg prompt "$PROMPT_TEXT" \
  --arg msg "$SYSTEM_MSG" \
  '{
    "decision": "block",
    "reason": $prompt,
    "systemMessage": $msg
  }'

exit 0
