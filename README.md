<p align="center">
  <img src="Xkeys/Resources/DesignAssets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" alt="Xkeys">
</p>

# Xkeys

[![Release](https://github.com/den0206/xkeys/actions/workflows/release.yml/badge.svg)](https://github.com/den0206/xkeys/actions/workflows/release.yml)

**English** | [日本語](README_JP.md)

A macOS app for managing Apple Developer keys, certificates, and provisioning profiles. Organize credentials by team, app, and target, keep the original files encrypted on your Mac, and track expiry dates in the app.

**Xkeys is built security-first, because signing keys, certificates, and API keys are secrets you cannot afford to leak.** Secrets are always encrypted at rest, every access requires you to authenticate, and nothing is ever sent to a third-party server.

<p align="center">
  <img src="media/xkeys-demo.gif" width="720" alt="Demo: scattered key, certificate, and profile files are sorted by team and app and encrypted, backed up with a password, and kept on this Mac">
</p>

<p align="center"><a href="media/xkeys-intro.mp4">Watch the 30-second intro video (MP4)</a></p>

## Security

Xkeys layers several defenses so that no single failure exposes your secrets.

### Encryption at rest

- **Original files, notes, `.p12` passwords, and custom secrets are all encrypted with AES-256-GCM.** The vault never holds plaintext secrets.
- The encryption key lives in this Mac’s **device-only Keychain** (`WhenUnlockedThisDeviceOnly`). It never migrates to another Mac or syncs through iCloud Keychain, and it cannot be read while the Mac is locked. After moving to a new Mac, use “Quarantine Unreadable Data…” in Restore from Backup, then restore a backup.
- Each ciphertext is **cryptographically bound** to its metadata, such as kind, team, and key purpose, as AES-GCM additional authenticated data. Swapping or reassigning encrypted files makes decryption fail, so tampering is detected.
- Metadata such as names, identifiers, and expiry dates is stored separately in SwiftData.

### Authentication before access

- The encryption key cannot be used without **Touch ID or your Mac password** (Keychain access control `userPresence`).
- **Every operation that touches a secret requires authentication**: viewing, copying, exporting, editing, and deleting. By default one approval is reused for 5 minutes and ends early on sleep, screen lock, or user switching; turn off "Keep approval for 5 minutes" in Settings to authenticate every time.

### No leak paths

- **Nothing is sent to third-party servers.** Network requests go only to Apple (`idmsa.apple.com`, `developer.apple.com`, and `appstoreconnect.apple.com`) for sign-in, team verification, and online imports. There are no analytics, advertising, or tracking services.
- No iCloud sync and no automatic launch at login.
- **Clipboard** copies stay on this Mac (excluded from Universal Clipboard), are marked `ConcealedType` so clipboard managers skip them, and are **cleared automatically after 60 seconds**.
- Apple Developer sign-in uses [XcodesLoginKit](https://github.com/XcodesOrg/XcodesLoginKit). Apple Account passwords and verification codes are never saved. Session cookies are stored in the device-only Keychain and removed on logout.
- Responses from Apple are validated for size and item count before processing.

### Backups

- Password-protected backups derive their key with **PBKDF2-HMAC-SHA256 (600,000 iterations)** and are encrypted with AES-256-GCM. Tampered backups are rejected on restore.
- Restoring a backup containing unregistered teams requires verification of membership in every such team. If membership cannot be verified, those backups cannot be restored. Backups containing only registered teams can be restored offline.

### The app itself

- **App Sandbox** and **Hardened Runtime** are enabled. The app can access only its own container and files you choose.
- Release builds are signed with Developer ID and **notarized by Apple**. Building, signing, and notarization run in GitHub Actions, never on a personal Mac.

### What stays in your hands

- Exported original files, **backups without a password**, and CI `.env` files are outside the vault’s encryption. Store backups safely and delete exported secret files after registering their values in CI.

Online integration uses Apple’s private web APIs and may need updates when Apple changes them. Trusted-device and SMS verification codes are supported; federated authentication and security keys are not supported. Xkeys cannot retrieve previously downloaded `.p8` files or certificate private keys, and does not check online revocation status.

Details (Japanese): [Design and storage format](docs/DESIGN.md).

## Requirements

- macOS 26.0 or later
- Apple Developer team membership to register teams and import credentials online
- For development: Xcode 27.0 / Swift 6.4 and Apple Development signing

## Install

Release builds are distributed through [this repository’s GitHub Releases](https://github.com/den0206/xkeys/releases). When a release is available, download `Xkeys-X.Y.Z.dmg`, open it, and drag `Xkeys.app` to `/Applications` along the arrow in the window. If you open Xkeys directly from the DMG, it shows how to move it first.

You can also install it with [Homebrew](https://brew.sh). This repository serves as the tap:

```sh
brew tap den0206/xkeys https://github.com/den0206/xkeys
brew trust --cask den0206/xkeys/xkeys
brew install --cask xkeys
```

Homebrew loads casks from third-party taps only after you trust them; `brew trust --cask` trusts just this cask, not every cask the tap may add later.

`brew uninstall --cask --zap xkeys` also deletes the app’s container (`~/Library/Containers/com.yuuki.xkeys`), including the encrypted vault. Create a backup first. The encryption key and Apple Developer session in the Keychain are not removed.

The release workflow signs the app with Developer ID and notarizes the DMG. Xkeys is not distributed through the Mac App Store.

## Features

- Store custom per-app key/value secrets with encrypted values, authenticated editing, and dotenv export

- Import `.p8`, `.cer`, `.p12`, `.mobileprovision`, and `.provisionprofile` files, individually or in batches
- Review duplicate .p12 candidates by their complete certificate set, even when filenames or passwords differ
- Sign in to Apple Developer to register teams and download certificates and provisioning profiles
- Group a main app, extensions, and widgets by their Bundle IDs
- View expiry dates, search across teams, and filter by credential type
- Keep encrypted notes and optionally save `.p12` passwords
- Copy credential values or export original files after authentication
- Create CI secret files in `.env` format
- Restore deleted items for 30 days
- Create password-protected backups and restore with conflict review
- Japanese and English UI, following the system language

To get started, sign in to Apple Developer, choose a team, add your apps, and import files. Keys and certificates are shared within a team; provisioning profiles belong to individual app targets.

Detailed instructions (Japanese): [User guide](docs/USAGE.md).

## Development

### Xcode

Open `Xkeys.xcodeproj`, select the **Xkeys** scheme and **My Mac**, and run. In **Signing & Capabilities**, select your development team for both **Xkeys** and **XkeysTests** and ensure the dedicated Keychain Sharing group is configured. Sensitive storage requires Apple Development signing; ad hoc signing is not supported.

### VS Code / Cursor

1. Install the recommended **CodeLLDB** extension.
2. Open the repository root.
3. Select **Run Xkeys Debug.app** in Run and Debug, then press **F5**.

The debug build is named **Xkeys Dev** and uses a separate container and encryption key from the release app.

### Command line

```sh
xcodebuild -project Xkeys.xcodeproj -scheme Xkeys \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/xcode build

xcodebuild -project Xkeys.xcodeproj -scheme Xkeys \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/xkeys-tests test
```

The test scheme uses `XKEYS_TESTING=1`, in-memory storage, temporary files, and injected keys. Do not use production credentials or backups for tests.

Signing troubleshooting and verification scope (Japanese): [Development guide](docs/IMPLEMENTATION.md).

## Release

Pushing a `release/Ver_X.Y.Z` branch runs the Release workflow: validate the version, release notes, and required secrets; run tests; build and sign the app and DMG; notarize the DMG; publish it to GitHub Releases; and move the English `[Unreleased]` notes in `CHANGELOG.md` into the released version on `main`, along with the version and sha256 in the Homebrew cask `Casks/xkeys.rb`.

Distribution runs through GitHub Actions. Signing credentials belong in GitHub Actions Secrets; never commit their values or exported `.env` files.

Details (Japanese): [Release guide](docs/RELEASE.md).

## Documentation

The detailed guides below are in Japanese; the changelog is in English.

- [User guide](docs/USAGE.md)
- [Design and storage format](docs/DESIGN.md)
- [Development and verification](docs/IMPLEMENTATION.md)
- [Release guide](docs/RELEASE.md)
- [Documentation security review](docs/SECURITY_REVIEW.md)
- [Changelog](CHANGELOG.md)

## Project layout

```text
Xkeys/Application/      App entry point and windows
Xkeys/Features/         Screens and user workflows
Xkeys/Models/           Teams, apps, and validation
Xkeys/Services/         Parsing, authentication, search, and preferences
Xkeys/Persistence/      Encrypted storage, backups, and restore
Xkeys/Resources/        Assets and localization
XkeysTests/             XCTest and synthetic fixtures
scripts/                Notarization script
Casks/                  Homebrew cask
.github/workflows/      Release workflow
docs/                   User, design, development, and release guides
media/                  Demo GIF and intro video for this README
```

## Status

The scope of completed checks and remaining on-device checks is tracked in the [Development guide](docs/IMPLEMENTATION.md). These records do not mean that every production workflow has been verified.

## License

Copyright (c) 2026 Yuuki Sakai.

Original code in this repository is licensed under the GNU General Public License
version 3 only (`GPL-3.0-only`). See [LICENSE](LICENSE) for the full terms.
Third-party dependencies retain their own licenses.
