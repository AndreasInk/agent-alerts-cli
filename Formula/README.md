# Homebrew formula

The first stable formula is generated from real release archives, not placeholder URLs or checksums.

The tag release workflow creates `agentalerts.rb` alongside the Apple Silicon and Intel archives. After verifying the release, copy that formula to `Formula/agentalerts.rb` in this repository and publish the change. See [releasing](../docs/releasing.md).

The formula installs the prebuilt executable, so Homebrew needs neither Node nor a Swift toolchain and does not download Swift packages during installation.
