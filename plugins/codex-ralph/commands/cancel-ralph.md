---
description: "Cancel active Ralph Wiggum loop"
allowed-tools: ["Bash(test -f .claude/codex-ralph.local.md:*)", "Bash(rm .claude/codex-ralph.local.md)", "Read(.claude/codex-ralph.local.md)"]
hide-from-slash-command-tool: "true"
---

# Cancel Ralph

To cancel the Ralph loop:

1. Check if `.claude/codex-ralph.local.md` exists using Bash: `test -f .claude/codex-ralph.local.md && echo "EXISTS" || echo "NOT_FOUND"`

2. **If NOT_FOUND**: Say "No active Ralph loop found."

3. **If EXISTS**:
   - Read `.claude/codex-ralph.local.md` to get the current iteration number from the `iteration:` field
   - Remove state and codex-ralph artifacts:
     ```bash
     rm -f .claude/codex-ralph.local.md .claude/codex-ralph-run-*.sh .claude/codex-ralph-prompt-*.txt
     ```
   - Report: "Cancelled codex-ralph loop (was at iteration N)" where N is the iteration value
