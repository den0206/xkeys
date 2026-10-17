# Changelog

All notable changes to Xkeys are documented here.

The format follows Keep a Changelog conventions and releases use semantic version tags (`vX.Y.Z`).

## [Unreleased]

### Added

- Encrypted per-app key/value storage with validation and backup v1 support.

### Changed

- Warn during import when a .p12 contains the same certificates as an existing or queued item, even if its password or filename differs.

- Licensed the original code under GPL-3.0-only and added the license text.

- Added English and Japanese READMEs, separate usage documentation, and a pre-publication documentation security review.

## [0.1.0] — 2026-10-17

### Added

- Encrypted local storage for Apple Developer keys, certificates and provisioning profiles, unlocked with Touch ID or the Mac password.
- Apple Developer sign-in to register teams and import certificates and profiles online.
- Apps with multiple targets, expiry overview with Dock badge, search and type filters.
- Delete and restore with Recently Deleted, password-protected backups and merge restore.
- CI secret file export in `.env` format.
- English localization.
