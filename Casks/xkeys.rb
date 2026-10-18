cask "xkeys" do
  version "0.1.1"
  sha256 "e243fe81d0780f9f3810fe232bc9768e231a0384b03f6f4f3b59d4b09d8f9229"

  url "https://github.com/den0206/xkeys/releases/download/v#{version}/Xkeys-#{version}.dmg"
  name "Xkeys"
  desc "Manage Apple Developer keys, certificates and provisioning profiles"
  homepage "https://github.com/den0206/xkeys"

  depends_on macos: :tahoe

  app "Xkeys.app"

  zap trash: "~/Library/Containers/com.yuuki.xkeys"
end
