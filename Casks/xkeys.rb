cask "xkeys" do
  version "0.1.0"
  sha256 "da972e25a7a97ef5aaee59125a48bb7e17f8351802aeb0feb1bf7aa11aa6e189"

  url "https://github.com/den0206/xkeys/releases/download/v#{version}/Xkeys-#{version}.dmg"
  name "Xkeys"
  desc "Manage Apple Developer keys, certificates and provisioning profiles"
  homepage "https://github.com/den0206/xkeys"

  depends_on macos: :tahoe

  app "Xkeys.app"

  zap trash: "~/Library/Containers/com.yuuki.xkeys"
end
