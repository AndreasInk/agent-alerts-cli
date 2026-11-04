# Homebrew formula

`agentalerts.rb` installs the latest packaged release from checksum-verified Apple Silicon and Intel archives.

For each new version, the tag release workflow creates `agentalerts.rb` alongside the archives. After verifying the release, copy that formula to `Formula/agentalerts.rb` in this repository and publish the change. See [releasing](../docs/releasing.md).

The formula installs the prebuilt executable, so Homebrew needs neither Node nor a Swift toolchain and does not download Swift packages during installation.
