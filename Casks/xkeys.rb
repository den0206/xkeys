cask "xkeys" do
  version "0.2.0"
  sha256 "518dbeb3a2101964b2ceaa63f20a5c8222005a01e1d29710395cf993e3513e46"

  url "https://github.com/den0206/xkeys/releases/download/v#{version}/Xkeys-#{version}.dmg"
  name "Xkeys"
  desc "Manage Apple Developer keys, certificates and provisioning profiles"
  homepage "https://github.com/den0206/xkeys"

  depends_on macos: :tahoe

  app "Xkeys.app"

  zap trash: "~/Library/Containers/com.yuuki.xkeys"
end
