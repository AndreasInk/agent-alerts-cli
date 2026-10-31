# Agent Alerts CLI

This standalone Swift package supplies `agentalerts setup`, `send`, and `hooks`.
Keep that surface small. Scheduling and account management belong elsewhere.

- Target macOS 13+, Swift 6. Use Swift Argument Parser and native Foundation networking.
- `swift test` verifies behavior; `scripts/smoke-test.sh .build/debug/agentalerts` checks the executable against isolated configuration.
- Never run development hook installation against the user's real agent configuration. Use temporary `CODEX_HOME`, `CLAUDE_CONFIG_DIR`, `XDG_CONFIG_HOME`, and `XDG_CACHE_HOME` values.
- Only `https://www.andreas.ink/api/agent` is the hosted send endpoint. Never embed privileged credentials or send tokens in arguments, URLs, logs, or tracked files.
- Tokens come from the environment or a regular current-user-owned, mode-0600 token file. Keep file permissions, owner checks, and symlink protections intact.
- Hook installers preserve unrelated settings; uninstall removes only managed hooks. Passive failures remain neutral. Opt-in phone permission hooks wait synchronously and return only a matching interaction's explicit yes/no decision for that one request; failures never grant permission or alter session rules.
- Passive alerts contain generic status and the project basename. Opt-in phone approvals send a complete bounded command or file target with common credentials redacted; unsupported actions stay in the native UI. Never read transcripts or transmit conversation content.
- `UserPromptSubmit` reports Planning when `permission_mode` is `plan`, otherwise Working. `Stop` reports Plan updated in plan mode and Finished otherwise; only Claude's explicit `ExitPlanMode` reports Plan ready. A stopped turn does not prove a whole goal is complete.
- Quiet planning/working events bypass snoozing; passive terminal and attention notifications respect it. Phone approval requests bypass snoozing and wait for a reply. Do not infer goal completion percentages; explicit milestone text belongs in manual sends.
- Snoozing drops notifying hook events while the Mac is active. No background queue or daemon.
- Deduplicate only explicit source request IDs. Missing or distinct IDs must not be collapsed. A disposable cache cannot be a prerequisite for delivery.
- Both sending and reply polling use the public endpoint. Polling sends `operation: "interaction_status"`, the fresh interaction ID, and the same originating interactive token. Never reuse decisions or treat pending, expired, or malformed responses as approval.
- Network/APNs acceptance and actual iPhone rendering are separate claims. Mock requests do not prove live delivery.
- Keep `--version` and release tags aligned. Release tools must use checksums from real artifacts; never invent a release URL or checksum.

Release preparation and manual acceptance checks live in [docs/releasing.md](docs/releasing.md).

- Passive Codex `PermissionRequest` events must stay silent: they run before auto-review routing and do not establish user attention. Explicit phone approval mode uses its separate coordinator.
- Passive Claude approval alerts use only `Notification` with `notification_type: "permission_prompt"`; early `PermissionRequest` hooks may be answered automatically and must stay silent.
