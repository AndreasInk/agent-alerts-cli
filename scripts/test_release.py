#!/usr/bin/env python3
"""Check formula generation without signing, GitHub, or Homebrew access."""

import hashlib
from pathlib import Path
import tempfile
import unittest

import release


class FormulaTests(unittest.TestCase):
    def test_requires_both_archives(self):
        with tempfile.TemporaryDirectory() as temporary:
            artifacts = Path(temporary)
            with self.assertRaisesRegex(ValueError, "Missing release archive"):
                release.formula_text("0.1.0", "AndreasInk/agent-alerts-cli", artifacts)
            (artifacts / release.archive_name("0.1.0", "arm64")).write_bytes(b"arm archive")
            with self.assertRaisesRegex(ValueError, "x86_64"):
                release.formula_text("0.1.0", "AndreasInk/agent-alerts-cli", artifacts)

    def test_uses_actual_artifact_hashes_and_matching_urls(self):
        with tempfile.TemporaryDirectory() as temporary:
            artifacts = Path(temporary)
            for arch in release.ARCHITECTURES:
                (artifacts / release.archive_name("0.1.0", arch)).write_bytes(arch.encode())
            formula = release.formula_text("0.1.0", "AndreasInk/agent-alerts-cli", artifacts)
            for arch in release.ARCHITECTURES:
                archive = artifacts / release.archive_name("0.1.0", arch)
                self.assertIn(hashlib.sha256(archive.read_bytes()).hexdigest(), formula)
                self.assertIn(f"/releases/download/v0.1.0/{archive.name}", formula)
            self.assertIn('bin.install "agentalerts"', formula)
            self.assertIn('depends_on macos: :ventura', formula)
            self.assertNotIn('system "swift"', formula)
            # The formula must follow changed bytes rather than reuse an old hash.
            changed = artifacts / release.archive_name("0.1.0", "arm64")
            old_hash = hashlib.sha256(changed.read_bytes()).hexdigest()
            changed.write_bytes(b"new archive bytes")
            updated = release.formula_text("0.1.0", "AndreasInk/agent-alerts-cli", artifacts)
            self.assertNotIn(old_hash, updated)
            self.assertIn(hashlib.sha256(changed.read_bytes()).hexdigest(), updated)

    def test_rejects_unsafe_version_repository_and_architecture(self):
        for version in ("v0.1.0", "0.1", "../bad", '0.1.0"'):
            with self.assertRaises(ValueError):
                release.archive_name(version, "arm64")
        for repository in ("owner", "owner/repo/extra", 'owner/repo"'):
            with self.assertRaises(ValueError):
                release.formula_text("0.1.0", repository, ".")
        with self.assertRaises(ValueError):
            release.archive_name("0.1.0", "unsupported")


if __name__ == "__main__":
    unittest.main()
