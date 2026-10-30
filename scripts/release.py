#!/usr/bin/env python3
"""Generate a Homebrew formula from the two release archives' actual checksums."""

import argparse
import hashlib
from pathlib import Path
import re


ARCHITECTURES = ("arm64", "x86_64")


def archive_name(version, arch):
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?", version):
        raise ValueError("Version must be a semantic version, such as 0.1.0.")
    if arch not in ARCHITECTURES:
        raise ValueError("Unsupported architecture.")
    return f"agentalerts-v{version}-macos-{arch}.tar.gz"


def checksum(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def formula_text(version, repository, artifacts):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Repository must have the form OWNER/REPOSITORY.")
    artifacts = Path(artifacts)
    hashes = {}
    for arch in ARCHITECTURES:
        archive = artifacts / archive_name(version, arch)
        if not archive.is_file():
            raise ValueError(f"Missing release archive: {archive.name}")
        hashes[arch] = checksum(archive)
    base = f"https://github.com/{repository}"
    return f'''class Agentalerts < Formula
  desc "iPhone Live Activities and agent hooks from your terminal"
  homepage "{base}"
  version "{version}"
  license "MIT"

  depends_on :macos
  depends_on macos: :ventura

  on_arm do
    url "{base}/releases/download/v{version}/{archive_name(version, "arm64")}"
    sha256 "{hashes["arm64"]}"
  end

  on_intel do
    url "{base}/releases/download/v{version}/{archive_name(version, "x86_64")}"
    sha256 "{hashes["x86_64"]}"
  end

  def install
    bin.install "agentalerts"
    doc.install "README.md"
  end

  test do
    assert_match "agentalerts", shell_output("#{{bin}}/agentalerts --help")
    assert_equal version.to_s, shell_output("#{{bin}}/agentalerts --version").strip
  end
end
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--artifacts", default="dist")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        text = formula_text(args.version, args.repository, args.artifacts)
        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(text, encoding="utf-8")
    except (ValueError, OSError) as error:
        parser.exit(1, f"Formula generation failed: {error}\n")
    print(output)


if __name__ == "__main__":
    main()
