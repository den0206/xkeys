cask "xkeys" do
  version "0.2.2"
  sha256 "8589acf9eb03253144b527b5aa4c3f25729a0934d1e644b824118429964f0c44"

  url "https://github.com/den0206/xkeys/releases/download/v#{version}/Xkeys-#{version}.dmg"
  name "Xkeys"
  desc "Manage Apple Developer keys, certificates and provisioning profiles"
  homepage "https://github.com/den0206/xkeys"

  depends_on macos: :tahoe

  app "Xkeys.app"

  zap trash: "~/Library/Containers/com.yuuki.xkeys"
end
