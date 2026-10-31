# Releasing

Release automation targets `AndreasInk/agent-alerts-cli`. The first binary release and Homebrew formula are still pending.

## Prepare a release

1. Update the CLI's `--version`, run `swift test` and `scripts/smoke-test.sh .build/debug/agentalerts`, and commit the reviewed source.
2. Check actual agent behavior: Planning/Working updates reach the Live Activity while active; notifying hooks send regardless of Mac activity. Verify mode labels, completion/attention events, Codex trust review, and preserved unrelated hooks after uninstall. Repeated explicit request IDs should deduplicate; distinct or unidentified requests must each deliver, and corrupt caches must recover. Confirm actual iPhone rendering separately from API acceptance. Explicit milestones must reuse the requested activity ID without invented completion percentages.
3. Create a `vVERSION` tag matching `--version`, then push it when release publication is authorized.

Before enabling `--approvals phone`, deploy the webhook's `interaction_status`
operation and connect with `setup --access interactive`. Check both agents with
a genuine pending permission request: no action before the matching phone Yes,
No denies just that request, pending continues waiting, and old/expired/error
responses never approve. The permission hook is synchronous with a 24-hour wait
and an 86,415-second host timeout. Other hooks stay at eight seconds. Also check
cancellation and local fallback for unsupported or oversized actions. Claude's
questions, plan approval, and sandbox-network prompts remain native UI paths.

The tag workflow tests and builds on Apple Silicon and Intel macOS runners with a macOS 13 deployment target. It publishes:

- `agentalerts-vVERSION-macos-arm64.tar.gz`
- `agentalerts-vVERSION-macos-x86_64.tar.gz`
- `SHA256SUMS`
- `agentalerts.rb`, generated from the two binary archive checksums

GitHub supplies the tagged source archives automatically. Binary archives use standard `tar`; `shasum` records the exact published bytes. The workflow uses an ephemeral ad-hoc signature for the executables; Developer ID signing and notarization are not configured. No signing credentials are required or included.

## Publish the Homebrew formula

Download and review the release's generated `agentalerts.rb`. Verify `SHA256SUMS` before installing either archive:

```bash
shasum -a 256 -c SHA256SUMS
```

This command expects all files listed in `SHA256SUMS` in the current directory. Copy the reviewed formula to `Formula/agentalerts.rb` and commit it. The checksums and URLs must refer to the published assets for the matching tag. The workflow does not commit or push a formula automatically.

After the repository and release exist, the same repository can be used as a tap:

```bash
brew tap andreasink/agent-alerts-cli https://github.com/AndreasInk/agent-alerts-cli.git
brew install andreasink/agent-alerts-cli/agentalerts
brew test andreasink/agent-alerts-cli/agentalerts
```

Review any Homebrew trust prompt for the tap. Test installation and upgrade on both architectures before claiming Homebrew support. After upgrade, an already-installed hook must continue using the stable executable path.

## Generate the formula locally

After downloading both architecture archives from the same release:

```bash
python3 scripts/release.py --version 0.1.0 \
  --repository AndreasInk/agent-alerts-cli --artifacts dist --output dist/agentalerts.rb
```

The tag workflow owns binary version/architecture checks, ad-hoc signing, and archive creation. The Python script only generates the Homebrew formula from real archive checksums. Run `python3 scripts/test_release.py` to verify missing-artifact handling, input validation, and checksum-backed formula generation without credentials or publication.
