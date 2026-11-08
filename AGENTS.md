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
- `UserPromptSubmit` reports Planning when `permission_mode` is `plan`, otherwise Working. `Stop` reports Plan updated in plan mode and Turn finished otherwise; only Claude's explicit `ExitPlanMode` reports Plan ready. A stopped turn does not prove a whole goal is complete. Only `SessionEnd` ends and immediately dismisses the session's activity.
- `PostToolUse` and `SubagentStart` report quiet generic stages from a fixed allowlist, at most once per 60 seconds and only when the stage changes. Never infer command success or read tool inputs/outputs. Progress uses `update_existing`. Prompts and supported notifying statuses retain upsert delivery when no active instance exists. Session-end markers block later tool/status updates until a new prompt.
- Session-end cleanup is quiet and synchronous, with a three-second host limit and two-second network budget. It is best effort, without retries or background workers. Abrupt termination may not emit it.
- Planning/working events update quietly; supported terminal and attention events notify regardless of Mac activity. Do not measure keyboard/mouse idle time. Accept legacy idle flags only for installed-hook compatibility. Phone approval requests wait for a reply. Do not infer goal completion percentages; explicit milestone text belongs in manual sends.
- No background queue or daemon.
- Deduplicate attention alerts only by explicit source request IDs. Missing or distinct IDs must not be collapsed. A disposable cache cannot block attention or terminal cleanup. Optional progress is skipped when its rate-limit cache is unavailable.
- Preserve existing hook group/handler indices when updating managed entries. Codex trust and disabled state depend on those indices. Never edit trusted hashes or enable disabled hooks.
- Both sending and reply polling use the public endpoint. Polling sends `operation: "interaction_status"`, the fresh interaction ID, and the same originating interactive token. Never reuse decisions or treat pending, expired, or malformed responses as approval.
- Network/APNs acceptance and actual iPhone rendering are separate claims. Mock requests do not prove live delivery.
- `send --file` reads a canonical content-state object, without a transport envelope. Reuse headline-send routing/notification defaults, generate fresh timestamps/keys, and preflight the 4096-byte APNs budget including a possible upsert start. The service owns detailed builder node validation. Keep examples free of timestamps, tokens, and routing keys.
- End events use `update_existing` so the service targets the matching registered instance without starting another activity.
- Keep `--version` and release tags aligned. Release tools must use checksums from real artifacts; never invent a release URL or checksum.

Release preparation and manual acceptance checks live in [docs/releasing.md](docs/releasing.md).

- Passive Codex `PermissionRequest` events must stay silent: they run before auto-review routing and do not establish user attention. Explicit phone approval mode uses its separate coordinator.
- Passive Claude approval alerts use only `Notification` with `notification_type: "permission_prompt"`; early `PermissionRequest` hooks may be answered automatically and must stay silent.
