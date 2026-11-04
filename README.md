# Agent Alerts CLI

Send Live Activities to your iPhone from the terminal. Get updates when Codex or Claude is working, finishes, or needs your attention.

Requires macOS 13+ and [Agent Alerts](https://www.andreas.ink/agent-alerts) on your iPhone.

## Install

Install the prebuilt Swift CLI with Homebrew:

```bash
brew tap andreasink/agent-alerts-cli https://github.com/AndreasInk/agent-alerts-cli.git
brew install andreasink/agent-alerts-cli/agentalerts
agentalerts --version
```

To build from source instead, use Swift 6+:

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

## Send a Live Activity

```bash
agentalerts send "Build finished"
agentalerts send "Tests failed" --summary "Open the test report." --status critical
```

These commands start or update a Live Activity and send a notification. Reuse an ID to follow one task:

```bash
agentalerts send "Building" --activity-id build --event start
agentalerts send "Running tests" --activity-id build
agentalerts send "Build finished" --activity-id build --event end
```

The final command closes the activity. Without `--activity-id`, sends share an ID for the current directory.

## Custom layouts

Use a JSON file to arrange text, metrics, charts, and progress indicators:

```bash
agentalerts send --file examples/progress.json --activity-id checks
agentalerts send --file examples/build-health.json --activity-id build-health
```

Start with the [progress layout](examples/progress.json) or [build health layout](examples/build-health.json). Edit the file and send it again with the same ID to update it. Each send replaces the content, so include the full layout.

Layouts use supported native components. See the [layout guide](docs/usage.md#custom-layouts) for the JSON format and limits, or run `agentalerts send --help` for command options.

## Connect your agents

```bash
agentalerts hooks install
```

This detects Codex and Claude and adds automatic status updates. In Codex, open `/hooks` to review and trust them. Restart an existing agent session to load the changes.

Check or remove the integration:

```bash
agentalerts hooks status
agentalerts hooks uninstall
```

Ordinary updates share the project name and agent status, without sending your conversations.

Phone approvals aren't available yet. See the [usage guide](docs/usage.md#phone-approvals) for their current requirements and limitations.

[More options and configuration](docs/usage.md) · [Development and releases](docs/releasing.md)
