<p align="center">
  <img src="Xkeys/Resources/DesignAssets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" alt="Xkeys">
</p>

# Xkeys

[![Release](https://github.com/den0206/xkeys/actions/workflows/release.yml/badge.svg)](https://github.com/den0206/xkeys/actions/workflows/release.yml)

**English** | [日本語](README_JP.md)

A macOS app for managing Apple Developer keys, certificates, and provisioning profiles. Organize credentials by team, app, and target, keep the original files encrypted on your Mac, and track expiry dates in the app and Dock badge.

## Requirements

- macOS 26.0 or later
- Apple Developer team membership to register teams and import credentials online
- For development: Xcode 27.0 / Swift 6.4 and Apple Development signing

## Install

Release builds are distributed through [this repository’s GitHub Releases](https://github.com/den0206/xkeys/releases). When a release is available, download `Xkeys-X.Y.Z.dmg`, open it, and move `Xkeys.app` to `/Applications`.

The release workflow signs the app with Developer ID and notarizes the DMG. Xkeys is not distributed through the Mac App Store.

## Features

- Import `.p8`, `.cer`, `.p12`, `.mobileprovision`, and `.provisionprofile` files, individually or in batches
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

## Privacy and security

- Original credential files, notes, and saved `.p12` passwords are encrypted locally with AES-GCM. The encryption key is stored in this Mac’s device-only Keychain. Credential metadata, such as names, identifiers, and expiry dates, is stored separately in SwiftData.
- Sensitive operations require Touch ID or your Mac password. There is no iCloud sync or automatic launch at login.
- Apple Developer connections use [XcodesLoginKit](https://github.com/XcodesOrg/XcodesLoginKit). Apple Account passwords and verification codes are not saved. Session cookies are stored in this Mac’s Keychain and removed on logout.
- Network requests go to Apple (`idmsa.apple.com`, `developer.apple.com`, and `appstoreconnect.apple.com`) for sign-in, team verification, online imports, and key service lookup. There are no analytics, advertising, or tracking services.
- Exported original files, unprotected backups, and CI `.env` files are outside the vault’s encryption protection. Store backups safely and delete exported secret files after registering their values in CI.

Online integration uses Apple’s private web APIs and may need updates when Apple changes them. Trusted-device and SMS verification codes are supported; federated authentication and security keys are not supported. Xkeys cannot retrieve previously downloaded `.p8` files or certificate private keys, and does not check online revocation status.

Restoring a backup containing unregistered teams requires verification of membership in every such team. If membership cannot be verified, those backups cannot be restored. Backups containing only registered teams can be restored offline.

Details (Japanese): [Design and storage format](docs/DESIGN.md).

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

Pushing a `release/Ver_X.Y.Z` branch runs the Release workflow: validate the version, release notes, and required secrets; run tests; build and sign the app and DMG; notarize the DMG; publish it to GitHub Releases; and move the English `[Unreleased]` notes in `CHANGELOG.md` into the released version on `main`.

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
.github/workflows/      Release workflow
docs/                   User, design, development, and release guides
```

## Status

The scope of completed checks and remaining on-device checks is tracked in the [Development guide](docs/IMPLEMENTATION.md). These records do not mean that every production workflow has been verified.

## License

Copyright (c) 2026 Yuuki Sakai.

Original code in this repository is licensed under the GNU General Public License
version 3 only (`GPL-3.0-only`). See [LICENSE](LICENSE) for the full terms.
Third-party dependencies retain their own licenses.
