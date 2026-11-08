# Usage and configuration

Start with the [README](../README.md) for installation and your first alert.

## Send options

| Option | Default |
| --- | --- |
| `--summary TEXT` | Same as the title |
| `--activity-id ID` | Stable identifier for the current directory |
| `--status good\|warning\|critical` | `good` |
| `--event start\|update\|end` | `update`, starting an activity if needed |
| `--file PATH` | Read a JSON content file instead of a headline |
| `--json` | Print a machine-readable acknowledgement |

Keep titles to 32 characters and summaries to 96. Start/update also send a notification; ending closes the activity.

```bash
agentalerts send "Deploying" --activity-id deploy --event start
agentalerts send "Verifying" --activity-id deploy --summary "Checking the final tests."
agentalerts send "Deploy finished" --activity-id deploy --event end
```

Requests go to `https://www.andreas.ink/api/agent`. An acknowledgement describes service/APNs acceptance, not confirmation that an alert appeared on iPhone. Failed or incomplete sends return a nonzero exit code. The CLI does not automatically retry.

Updates reuse the activity with the supplied ID, starting one if needed. Explicit `start` requests a new activity; use the default update for repeat sends. `end` targets an existing activity and never starts one. If no matching activity is registered, it returns a nonzero exit code. After starting, the iPhone needs to register its update token before an update or end can reach that activity.

## Custom layouts

```bash
agentalerts send --file examples/progress.json --activity-id checks
# Edit the values in the file, then send the complete content again.
agentalerts send --file examples/progress.json --activity-id checks
agentalerts send "Checks finished" --activity-id checks --event end
```

Run these from the cloned repository, or use the path to your own JSON file. `--file` replaces the positional headline, `--summary`, and `--status`; put that content in the file. `--activity-id`, `--event`, and `--json` work with either input style. Normal sends remain `agentalerts send "Build finished"`.

The file is a Live Activity **content object**, without a `payload` wrapper. It requires `title` (up to 32 characters); `summary` defaults to the title and `status` defaults to `good`. The CLI adds the current timestamp, a fresh request key, and routing information on every send. Keep tokens, timestamps, activity IDs, and other request fields out of the file.

For a custom layout, set `template` to `builder` and provide a version-1 `builderSpec`. A minimal layout looks like:

```json
{
  "title": "Build finished",
  "template": "builder",
  "builderSpec": {
    "version": 1,
    "surfaces": {
      "lockScreen": { "type": "text", "text": "All checks passed", "role": "title" }
    }
  }
}
```

Copy either complete example:

| File | Layout |
| --- | --- |
| [progress.json](../examples/progress.json) | Check count beside a progress ring |
| [build-health.json](../examples/build-health.json) | Build time above a bar chart |

`surfaces.lockScreen` is required. Optional `compact`, `minimal`, and `expanded` surfaces customize the Dynamic Island; the app supplies fallbacks for omitted surfaces. Keep compact and minimal content short. The examples include both.

Use `vstack`, `hstack`, `zstack`, or `grid` to arrange `text`, `metric`, `chart`, `progress`, `documentPreview`, `statusDot`, `imageSymbol`, `button`, `spacer`, and `divider` nodes. These are constrained components rendered by the app; JSON cannot supply arbitrary SwiftUI, HTML, or code. The CLI sends literal layout content; it does not run scripts or expand variables.

Each container supports at most 8 children, with at most 5 levels of nesting below the root. Node text is limited to 96 characters, chart values to 16 numbers, and progress to 0–100. A layout file is limited to 64 KiB; the actual compact APNs message, including its service envelope, must fit within **4096 bytes**. The CLI checks a conservative budget, including a possible start when updating and room for the service's number formatting. The service validates component fields and bindings; invalid layouts fail the send. Keep the layout small enough to read on iPhone.

The supported file fields use camelCase: `title`, `summary`, `status`, `sourceName`, `sourceIcon`, `template`, `builderSpec`, `data`, `action`, `deepLink`, `inlineLabel`, `primaryLabel`, `primaryValue`, `primaryDelta`, `secondaryLabel`, `secondaryValue`, `footer`, `chartValues`, `chartTitle`, `chartStyle`, `progressPercent`, `completedSteps`, `totalSteps`, `progressStyle`, `visualStyle`, `accentHex`, and `glassOpacity`. The file is sent as complete content, without merging the previous activity's fields.

## Credentials

Setup saves the approved token in a current-user-owned, mode-`0600` `~/.config/agent-alerts/token.env`. `XDG_CONFIG_HOME` is respected. The file is parsed, never shell-sourced.

For scripts and CI, provide `AGENTALERTS_AGENT_TOKEN` through your secret environment. The CLI checks that variable first, then the token file, then the compatibility variable `REPORTKIT_AGENT_TOKEN`. Never put tokens in arguments, AI prompts, URLs, logs, or tracked files.

Setup reports when an environment token overrides the newly saved file. Saving a token does not verify delivery.

- `agentalerts setup --name "My Mac"` names the connection.
- `agentalerts setup --json` prints the pairing URL without opening a browser or prompting.

The Swift and existing TypeScript CLIs share the token file and executable name `agentalerts`. Choose which installation appears first on your `PATH`.

## Hooks

Automatic Live Activity cards use a concise state title (for example, “Turn finished”) and the project basename, without repeating the agent name. Notifications retain the agent name in their title.

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
