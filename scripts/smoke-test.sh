#!/bin/bash
set -euo pipefail

binary="${1:-.build/debug/agentalerts}"
binary="$(cd "$(dirname "$binary")" && pwd)/$(basename "$binary")"
task_temp="$(mktemp -d)"
task_temp="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$task_temp")"
trap 'rm -rf "$task_temp"' EXIT
export CODEX_HOME="$task_temp/codex"
export CLAUDE_CONFIG_DIR="$task_temp/claude"
export XDG_CONFIG_HOME="$task_temp/config"
export XDG_CACHE_HOME="$task_temp/cache"

"$binary" --help > "$task_temp/help"
for command in setup send hooks; do
  grep -q "$command" "$task_temp/help"
done
"$binary" --version
"$binary" send --help > /dev/null
"$binary" setup --json > "$task_temp/setup.json"
python3 - "$task_temp/setup.json" <<'PY'
import json
import sys
from urllib.parse import urlparse

result = json.load(open(sys.argv[1]))
url = urlparse(result["setup_url"])
assert url.scheme == "https" and url.netloc == "www.andreas.ink"
assert url.path == "/agent"
PY

"$binary" hooks install codex
cp "$CODEX_HOME/hooks.json" "$task_temp/original-hooks.json"
"$binary" hooks install codex
cmp "$CODEX_HOME/hooks.json" "$task_temp/original-hooks.json"
"$binary" hooks status
python3 - "$binary" "$CODEX_HOME/hooks.json" <<'PY'
import json
import subprocess
import sys

binary = sys.argv[1]
config = json.load(open(sys.argv[2]))
assert "--idle-seconds" not in json.dumps(config)
command = config["hooks"]["Stop"][0]["hooks"][0]["command"]
# Execute the actual generated shell command. An incomplete event never sends.
result = subprocess.run(["/bin/sh", "-c", command], input='{"hook_event_name":"Stop"}', text=True, capture_output=True, timeout=10)
assert result.returncode == 0 and json.loads(result.stdout) == {}
assert "session ID" in result.stderr
for arguments, event in [
    (["_hook", "codex", "--idle-seconds", "0"], "not JSON"),
    (["_hook", "not-an-agent"], "{}"),
]:
    result = subprocess.run([binary, *arguments], input=event, text=True, capture_output=True, timeout=10)
    assert result.returncode == 0 and json.loads(result.stdout) == {}
    assert "Agent Alerts hook:" in result.stderr
# Both new and previously installed invocations remain neutral without sending.
for agent in ["codex", "claude"]:
    for legacy in [[], ["--idle-seconds", "300"]]:
        result = subprocess.run([binary, "_hook", agent, *legacy], input='{"hook_event_name":"PermissionRequest"}', text=True, capture_output=True, timeout=10)
        assert result.returncode == 0 and json.loads(result.stdout) == {} and not result.stderr
help_result = subprocess.run([binary, "hooks", "install", "--help"], text=True, capture_output=True)
assert "--idle-seconds" not in help_result.stdout
# Legacy install options remain accepted but don't enter generated commands.
result = subprocess.run([binary, "hooks", "install", "codex", "--idle-seconds", "300"], text=True, capture_output=True)
assert result.returncode == 0
assert "--idle-seconds" not in open(sys.argv[2]).read()
# Misplaced credentials must be rejected before argument-parser diagnostics echo them.
credential = "rk_agent_" + "A" * 43
for arguments in [["setup", credential], ["send", "--token", credential], ["send", credential]]:
    result = subprocess.run([binary, *arguments], text=True, capture_output=True, timeout=10)
    assert result.returncode != 0
    assert credential not in result.stdout + result.stderr
    assert "Tokens cannot be passed" in result.stderr
PY
"$binary" hooks uninstall codex
"$binary" hooks install codex --approvals phone
python3 - "$binary" "$CODEX_HOME/hooks.json" <<'PY'
import json
import os
import subprocess
import sys

config = json.load(open(sys.argv[2]))
permission = config["hooks"]["PermissionRequest"][0]["hooks"][0]
assert permission["timeout"] == 86415
assert "--approvals phone" in permission["command"]
assert not permission.get("async", False)
# The private phone path must remain neutral when credentials are unavailable.
environment = os.environ.copy()
environment.pop("AGENTALERTS_AGENT_TOKEN", None)
environment.pop("REPORTKIT_AGENT_TOKEN", None)
result = subprocess.run(
    ["/bin/sh", "-c", permission["command"]], input='{"hook_event_name":"PermissionRequest"}',
    text=True, capture_output=True, env=environment, timeout=10,
)
assert result.returncode == 0 and json.loads(result.stdout) == {}
assert "No Agent Alerts token" in result.stderr
PY
"$binary" hooks uninstall codex
python3 - "$CODEX_HOME/hooks.json" <<'PY'
import json
import os
import sys

if os.path.exists(sys.argv[1]):
    config = json.load(open(sys.argv[1]))
    for groups in config.get("hooks", {}).values():
        for group in groups:
            for hook in group.get("hooks", []):
                assert " _hook " not in hook.get("command", "")
PY

if "$binary" send "Too long a title for a Live Activity headline" > "$task_temp/send-output" 2>&1; then
  echo "An over-budget title unexpectedly succeeded." >&2
  exit 1
fi
grep -q 'Title must be' "$task_temp/send-output"
printf '%s\n' 'Smoke test passed (isolated configuration; no sends).'
