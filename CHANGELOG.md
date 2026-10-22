# Changelog

All notable changes to Xkeys are documented here.

The format follows Keep a Changelog conventions and releases use semantic version tags (`vX.Y.Z`).

## [Unreleased]

## [0.2.0] — 2026-10-22

### Added

- Teams can have an icon, chosen as a color or a PNG, JPEG, or SVG image of up to 1 MB in "Edit Team…". It appears in the team switcher and the team list, and backups include it.

- Apps in the sidebar can be reordered by dragging or with "Move Up" and "Move Down" in the context menu. The order is kept on this Mac and is not included in backups.

- After you confirm with Touch ID, Xkeys doesn't ask again for 5 minutes. Sleep, locking the screen, or switching users ends it. Turn off "Keep approval for 5 minutes" in Settings to be asked every time.

### Removed

- The Dock badge that counted items expiring within 30 days, and its setting.

### Changed

- Copy buttons briefly turn into a checkmark, the Touch ID icon pulses while waiting for authentication, and finished backups, restores, imports, and CI file exports draw their checkmark. The CI copy countdown rolls its digits. Motion is off when Reduce Motion is on.

- Rows open their details smoothly, the sidebar highlight slides to the chosen page, and rows, sidebar items, and buttons respond to hover and press. The drop target fades in while dragging files over a page, and a Force Touch trackpad gives a light tap when a copy, save, restore, import, or export succeeds.

- An app page shows its targets as a tree under the main app instead of filter buttons. Each target opens and closes from its header, closing the main app hides its targets too, and a closed header shows how many items need attention.

- Pages fill in from the top when they open, sections and targets grow and shrink as they open and close, and deleted rows slide away while the rows below close the gap. Adding files shows each file's details rising in and its mark changing in place, Settings fills in and confirms a save, and importing from Apple Developer shows placeholder rows while the list loads. Motion is off when Reduce Motion is on.

### Fixed

- Certificates now show the apps that use them right after a restore, instead of only after the next Touch ID prompt.

- A failed save, import, or restore no longer leaves its discarded changes in memory, where a later save could store them and point items at deleted files.

## [0.1.1] — 2026-10-18

### Added

- Guide mode for first-time developers: a five-step tour of the main window, “?” explanations beside profile, certificate, key, and Bundle ID headings, and a glossary. Turn it on from the toolbar, the onboarding, or Settings.

- A step-by-step renewal guide from “How to Fix” that explains why files stopped working and links to Apple Developer, import, deletion, and backup.

- A prompt to move Xkeys to the Applications folder when it is opened from the DMG or a translocated location, with a button that opens Finder.

- A laid-out DMG window with a background that shows dragging Xkeys to Applications.

- Homebrew cask (`brew tap den0206/xkeys https://github.com/den0206/xkeys && brew trust --cask den0206/xkeys/xkeys && brew install --cask xkeys`).

- Settings shows the app version and build number at the bottom.

- Apps with a saved note show a collapsible Notes section below custom secrets. The text appears after authentication and is hidden again when collapsed, locked, or after five minutes.

- Custom per-app key/value secrets with encrypted storage, authenticated editing and copying, dotenv export, and backup v1 support.

### Changed

- The onboarding has four steps, adding an overview of certificates, keys, and profiles, and a guide mode switch on the last step. It can be shown again from Settings.

- The welcome screen no longer mentions notifications, which Xkeys does not send.

- Apps in the sidebar are separated by dividers.

- Redrew the onboarding artwork on a blue blueprint background with the Xkeys name, and removed the notification shown in the security artwork. English artwork is shown when the app is not in Japanese.

- Collapse custom secrets by default, add authenticated copying on app pages, and clarify saving multiple keys together.

- Show custom secret names and an add button at the bottom of each app page.

- Keep custom secret drafts open when switching apps so values can be copied from other applications.

- Warn during import when a .p12 contains the same certificates as an existing or queued item, even if its password or filename differs.

- Licensed the original code under GPL-3.0-only and added the license text.

### Fixed

- A vault whose encryption key is missing, for example after moving to a new Mac, or whose stored files can't be decrypted no longer blocks backup and restore. “Quarantine Unreadable Data…” moves the unreadable files aside without deleting them, so a backup can be made or restored.
- Adding an app whose Bundle ID belongs to an app in Recently Deleted now says so.
- Notes can no longer be saved to an app in Recently Deleted.
- Saving an empty app note removes the note instead of storing an empty one.
- The first line of an encrypted note, and of a revealed custom secret value, is no longer drawn over the field border.
- Reading certificates in stored profiles and .p12 files, and reading a profile when adding an app, no longer blocks the main window.

- Added English and Japanese READMEs, separate usage documentation, and a pre-publication documentation security review.

## [0.1.0] — 2026-10-17

### Added

- Encrypted local storage for Apple Developer keys, certificates and provisioning profiles, unlocked with Touch ID or the Mac password.
- Apple Developer sign-in to register teams and import certificates and profiles online.
- Apps with multiple targets, expiry overview with Dock badge, search and type filters.
- Delete and restore with Recently Deleted, password-protected backups and merge restore.
- CI secret file export in `.env` format.
- English localization.
