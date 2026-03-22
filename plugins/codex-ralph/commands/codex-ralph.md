---
description: "Start codex-ralph loop: Claude Agent Team implements + Codex reviews, loop until approved"
argument-hint: "PROMPT [--max-iterations N] [--completion-promise TEXT]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup-ralph-loop.sh:*)"]
hide-from-slash-command-tool: "true"
---

# codex-ralph

Execute the setup script:

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-ralph-loop.sh" $ARGUMENTS
```

Work on the task with Agent Team. When done, output `<promise>DONE</promise>`.
The stop hook will automatically run a Codex review (gpt-5.3-codex/xhigh).
If Codex approves — session ends. If Codex finds issues — you'll see the findings and can fix them.

CRITICAL: Only output `<promise>DONE</promise>` when the task is genuinely complete.
