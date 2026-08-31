class Glassdock < Formula
  desc "Docker-compatible container engine for macOS on Apple Silicon"
  homepage "https://github.com/naaiyy/glassdock"
  version "1.3.1"
  license "Apache-2.0"

  depends_on arch: :arm64
  depends_on :macos

  url "https://github.com/naaiyy/glassdock/releases/download/v1.3.1/glassdock-1.3.1-macos-arm64.tar.gz"
  sha256 "719ad0865065c4bbed8b45c3e2d058df11c4b2bfaeb0ee6245a0ed672452240e"

  def install
    # Mirror the release layout so the daemon's artifact discovery works:
    # - libexec/glassdock/glassdock (daemon) with the VMM artifacts as siblings
    # - share/glassdock/ (inside the versioned Cellar) for kernel and root disk
    # - bin/glassdock wrapper script, unmodified
    libexec.install Dir["glassdock-#{version}-macos-arm64/libexec/glassdock/*"]
    (prefix/"share/glassdock").install Dir["glassdock-#{version}-macos-arm64/share/glassdock/*"]
    bin.install "glassdock-#{version}-macos-arm64/bin/glassdock"
  end

  service do
    run [opt_libexec/"glassdock/glassdock", "run"]
    keep_alive true
    require_root false
    log_path var/"log/glassdock.log"
    error_log_path var/"log/glassdock.err"
  end

  def caveats
    <<~EOS
      Requires macOS 26 (Tahoe) on Apple Silicon.

      Start and enable the daemon with Homebrew services:
        brew services start glassdock

      Then switch your Docker CLI to Glass Dock:
        docker context use glassdock

      Migrate your existing Docker state:
        glassdockctl migrate from-docker

      Note: `glassdockctl` is not yet bundled in the release archive. Build it
      from source (swift build --product glassdockctl) or install the .pkg.
    EOS
  end

  test do
    # The wrapper script resolves the daemon at <prefix>/libexec/glassdock/glassdock
    # and `version` works without a package-style install.
    assert_match version.to_s, shell_output("#{bin}/glassdock version")
  end
end
