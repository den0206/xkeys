cask "xkeys" do
  version "0.2.1"
  sha256 "f6f1f8f1860b4bba6a9148a6b423816c9ff70a8f5132dd430f3b9bf283871276"

  url "https://github.com/den0206/xkeys/releases/download/v#{version}/Xkeys-#{version}.dmg"
  name "Xkeys"
  desc "Manage Apple Developer keys, certificates and provisioning profiles"
  homepage "https://github.com/den0206/xkeys"

  depends_on macos: :tahoe

  app "Xkeys.app"

  zap trash: "~/Library/Containers/com.yuuki.xkeys"
end
