# Agent Alerts CLI

Send Live Activities to your iPhone from the terminal. Get updates when Codex or Claude is working, finishes, or needs your attention.

Requires macOS 13+ and [Agent Alerts](https://www.andreas.ink/agent-alerts) on your iPhone.

## Install

Homebrew support is coming. For now, build with Swift 6+:

```bash
git clone https://github.com/AndreasInk/agent-alerts-cli.git
cd agent-alerts-cli
swift build -c release --product agentalerts
install -d "$HOME/.local/bin"
install .build/release/agentalerts "$HOME/.local/bin/agentalerts"
```

Add `~/.local/bin` to your `PATH` if needed.

## Connect

```bash
agentalerts setup
```

Approve the connection on your iPhone, then paste the one-time token into the hidden terminal prompt.

## Send an alert

```bash
agentalerts send "Build finished"
agentalerts send "Tests failed" --summary "Open the test report." --status critical
```

Reuse `--activity-id` to update the same Live Activity. Run `agentalerts send --help` for more options.

## Connect your agents

```bash
agentalerts hooks install
```

This detects Codex and Claude and adds automatic status updates. In Codex, open `/hooks` to review and trust them. Restart an existing agent session to load the changes.

Passive Codex approval alerts are suppressed because its permission hook also fires for automatic review. Codex approval prompts remain in the native UI. Claude approval alerts use its delayed `permission_prompt` notification, so requests resolved before that notification stay silent. Explicit phone approval mode is separate.

Notifications are snoozed while you use your Mac. After five minutes away, they resume. Quiet Live Activity updates continue while you work.

To receive notifications even while active:

```bash
agentalerts hooks install --idle-seconds 0
```

Check or remove the integration:

```bash
agentalerts hooks status
agentalerts hooks uninstall
```

Ordinary updates share the project name and agent status, without sending your conversations.

Phone approvals aren't available yet. See the [usage guide](docs/usage.md#phone-approvals) for their current requirements and limitations.

[More options and configuration](docs/usage.md) · [Development and releases](docs/releasing.md)
