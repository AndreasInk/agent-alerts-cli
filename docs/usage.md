# Usage and configuration

Start with the [README](../README.md) for installation and your first alert.

## Send options

| Option | Default |
| --- | --- |
| `--summary TEXT` | Same as the title |
| `--activity-id ID` | Stable identifier for the current directory |
| `--status good\|warning\|critical` | `good` |
| `--event start\|update\|end` | `update`, starting an activity if needed |
| `--json` | Print a machine-readable acknowledgement |

Keep titles to 32 characters and summaries to 96. Start/update also send a notification; ending closes the activity.

```bash
agentalerts send "Deploying" --activity-id deploy --event start
agentalerts send "Verifying" --activity-id deploy --summary "Checking the final tests."
agentalerts send "Deploy finished" --activity-id deploy --event end
```

Requests go to `https://www.andreas.ink/api/agent`. An acknowledgement describes service/APNs acceptance, not confirmation that an alert appeared on iPhone. Failed or incomplete sends return a nonzero exit code. The CLI does not automatically retry.

## Credentials

Setup saves the approved token in a current-user-owned, mode-`0600` `~/.config/agent-alerts/token.env`. `XDG_CONFIG_HOME` is respected. The file is parsed, never shell-sourced.

For scripts and CI, provide `AGENTALERTS_AGENT_TOKEN` through your secret environment. The CLI checks that variable first, then the token file, then the compatibility variable `REPORTKIT_AGENT_TOKEN`. Never put tokens in arguments, AI prompts, URLs, logs, or tracked files.

Setup reports when an environment token overrides the newly saved file. Saving a token does not verify delivery.

- `agentalerts setup --name "My Mac"` names the connection.
- `agentalerts setup --json` prints the pairing URL without opening a browser or prompting.

The Swift and existing TypeScript CLIs share the token file and executable name `agentalerts`. Choose which installation appears first on your `PATH`.

## Hooks

Choose a specific agent:

```bash
agentalerts hooks install codex
agentalerts hooks install claude
agentalerts hooks uninstall codex
```

The installer preserves unrelated settings. Reinstalling matching settings makes no changes; uninstall removes only its own hooks.

- Codex: `$CODEX_HOME/hooks.json`, or `~/.codex/hooks.json`.
- Claude: `$CLAUDE_CONFIG_DIR/settings.json`, or `~/.claude/settings.json`.

Changed Codex hook definitions require another `/hooks` trust review.

| Agent event | Status |
| --- | --- |
| Prompt starts in plan mode | Planning |
| Prompt starts in another mode | Working |
| Turn stops in plan mode | Plan updated |
| Claude presents its plan for approval | Plan ready |
| Turn stops outside plan mode | Finished |
| Approval, question, or failure | Needs approval, needs input, or failed |

Planning/working update only the Live Activity. Other supported passive events also notify, regardless of Mac keyboard or mouse activity. Existing hook commands with `--idle-seconds` still work, but the value is ignored. New hooks omit the flag. The legacy install option is accepted but hidden from help.

Claude approval alerts use its delayed `permission_prompt` notification. Early permission requests stay silent for both agents so automatically handled approvals do not notify. Codex lacks an equivalent passive user-attention signal, so manual approval prompts remain in Codex.

Plan labels use the agent's reported mode. A stopped planning turn does not establish that an entire plan or goal is complete. Send goal milestones explicitly; the CLI does not estimate percentages. Passive hooks never read transcripts or send prompts, commands, or replies.

Deduplication uses explicit request IDs only. Corrupt caches recover; unavailable caches cannot stop delivery.

## Phone approvals

**Not available yet:** the code is prepared, but the public webhook's interaction-status operation still needs deployment and the full flow needs agent/iPhone verification.

After that update, phone approvals can be enabled with:

```bash
agentalerts setup --access interactive
agentalerts hooks install --approvals phone
```

Replies require an interactive connection and Agent Alerts Pro or Founder Pro. The current interactive setup flow also grants alarm access; review the exact permissions on iPhone.

Phone mode sends the pending tool name and complete command or file target, with common credential forms redacted. Long, multiline, and unsupported actions remain in the agent's native approval flow. Ordinary status updates remain unchanged.

For supported permission requests, the synchronous hook waits up to 24 hours for the matching **Yes** or **No** reply. Yes approves only that request; No denies it. Expiry, cancellation, unavailable delivery, malformed replies, and network errors never grant permission; approval remains in the native UI. An old reply cannot authorize a later request.

Claude's plan approval, questions, and sandbox-network prompts use different contracts and remain in Claude's native UI. The CLI does not change session permissions or bypass the agent's deny rules.

Restore local-only approval with `agentalerts hooks install --approvals local`.

## Development

```bash
swift test
scripts/smoke-test.sh .build/debug/agentalerts
```

Tests use temporary configuration and intercepted requests; no credentials or iPhone are required. Actual agent sessions and iPhone rendering need separate manual checks. See [releasing](releasing.md) for distribution and release verification.

The CLI has no scheduler, background service, analytics, or transcript processing.
