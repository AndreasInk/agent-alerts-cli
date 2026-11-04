class Agentalerts < Formula
  desc "iPhone Live Activities and agent hooks from your terminal"
  homepage "https://github.com/AndreasInk/agent-alerts-cli"
  license "MIT"

  depends_on macos: :ventura

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/AndreasInk/agent-alerts-cli/releases/download/v0.1.0/agentalerts-v0.1.0-macos-arm64.tar.gz"
      sha256 "29d4b5202027b0bccd2a3770fe438febd82eb5bb5fb947f3511e04cf2460136a"
    else
      url "https://github.com/AndreasInk/agent-alerts-cli/releases/download/v0.1.0/agentalerts-v0.1.0-macos-x86_64.tar.gz"
      sha256 "89b5c8152c55bffe6f8f80df741140448b38bb0d0b32efe33af9b9c574efb65a"
    end
  end

  def install
    bin.install "agentalerts"
    doc.install "README.md"
  end

  test do
    assert_match "agentalerts", shell_output("#{bin}/agentalerts --help")
    assert_equal version.to_s, shell_output("#{bin}/agentalerts --version").strip
    setup = JSON.parse(shell_output("#{bin}/agentalerts setup --json --name Homebrew"))
    assert_equal "https://www.andreas.ink/agent?name=Homebrew", setup.fetch("setup_url")
  end
end
