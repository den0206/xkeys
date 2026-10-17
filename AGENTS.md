# Repository Guidelines

## プロジェクト構成

Xkeys は macOS 26.0 以降向けの SwiftUI・SwiftData アプリです。Apple Developer認証にはXcodesLoginKitを使用します。それ以外の外部ライブラリ追加は必要性を確認してください。

- `Xkeys/Application/`：起動とウィンドウ構成。
- `Xkeys/Features/`：一覧、取り込み、設定、バックアップなどの画面。
- `Xkeys/Models/`：チーム・アプリのモデルと登録時の検証。
- `Xkeys/Services/`：解析、認証、検索、設定。
- `Xkeys/Persistence/`：暗号化保存、変更履歴、バックアップ・復元。
- `Xkeys/Resources/`：画像アセットと同梱リソース。
- `XkeysTests/`：XCTest と架空データの `Fixtures/`。
- `docs/DESIGN.md`：動作仕様。`docs/IMPLEMENTATION.md`：開発手順と確認範囲。`docs/RELEASE.md`：バージョンと配布手順。
- `.github/workflows/release.yml`・`scripts/notarize.sh`：`release/Ver_X.Y.Z` の push で署名・公証した DMG を GitHub Releases に公開します。手元の Mac からは配布しません。
- `CHANGELOG.md`：リリースノート。利用者に見える変更は `[Unreleased]` に英語で追記します。

## ビルド・実行

開発環境は Xcode 27.0・Swift 6.4、scheme は `Xkeys` です。

```sh
# 通常の Debug ビルド
xcodebuild -project Xkeys.xcodeproj -scheme Xkeys \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/xcode build

# 通常ビルドと出力先を分けてテスト
xcodebuild -project Xkeys.xcodeproj -scheme Xkeys \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/xkeys-tests test
```

テストは `XkeysTests/XkeysTests.swift` の `XkeysTests` クラスにまとまっています。1件だけ実行する場合は `test` の前に `-only-testing:XkeysTests/XkeysTests/testName` を付けます。

実行は Xcode の `My Mac`、または CodeLLDB を導入した VS Code / Cursor の F5 を使います。秘密情報の操作には Apple Development 署名が必要です。両ターゲットの Team を合わせ、署名設定は README に従ってください。

## アーキテクチャの要点

- 起動は `Application/XkeysApp.swift`。`XKEYS_TESTING=1` ならメモリ内の `ModelContainer` を使います。SwiftData のモデルを追加したら、ここの型一覧にも追加してください。
- メタデータ（`DeveloperTeam`・`ManagedApp`・`StoredCredential`）は SwiftData に保存します。元ファイル・メモ・.p12 パスワードは `CredentialPayload` として AES-GCM で暗号化し、`XkeysVault/blobs` に保存します。鍵は端末専用 Keychain（`EncryptionKeychain`）にあります。
- 暗号化 blob の AAD は `StoredCredential.authenticatedData()`（`XkeysCredential-v1`）と `VaultManagement.noteAAD` で作ります。AAD に含まれる項目（kind、所属、`keyPurpose` など）は自動で書き換えないでください。変えるときは別 UUID の blob に暗号化し直し、読み戻して検証してから参照を切り替えます（`VaultManagement.updatePurposes` を参照）。
- 取り込みは `CredentialVault`（`validate` → `importFile`）、編集・削除・復元・完全削除は `VaultManagement` が担当します。秘密情報の操作は `OwnerAuthentication` で毎回認証し、取得した `SymmetricKey` を渡します。
- データを変更する処理は、変更の前に `BackupHistory.prepare` を、変更時に `BackupHistory.record` を同じ context で呼び、未バックアップの変更を識別する印を記録します。変更回数は集計せず、バックアップの要否だけを表示します。バックアップ形式は `BackupArchive`（`BackupSnapshot` version 1）、復元は `BackupRestore` / `RestorePlan` です。
- Apple Developer 連携は `AppleDeveloperSession`（XcodesLoginKit、Cookie を Keychain に保存）と `AppleDeveloperClient`（非公開の Web API、応答サイズ・件数を検証）が担当します。HTTP と Keychain はテストで架空のものに差し替えます。
- 仕様を変えたら `docs/DESIGN.md`、確認範囲を変えたら `docs/IMPLEMENTATION.md`、操作を変えたら `README.md` も更新します。

## コーディング規約

既存コードに合わせ、インデントはスペース4個、型名は `UpperCamelCase`、関数・変数名は `lowerCamelCase` にします。ファイル名は主要な型や機能に合わせます。画面は `Features/`、保存処理は `Persistence/` に置き、同じ処理を画面ごとに複製しないでください。

UI 文言は日本語で書き、`Xkeys/Resources/Localizable.xcstrings` に英訳を追加します（OS の言語設定で切り替わります）。`Text` などに直接書けない文字列は `String(localized:)` で囲みます。`kind` など保存データや暗号化の AAD に入る文字列は翻訳しないでください。既存の `XkeysStyle` と標準コントロールを使います。専用の formatter・linter 設定はありません。変更後は `git diff --check` で空白の問題を確認してください。

## テスト方針

テスト名は `testTeamScopeIncludesAllSharedFormats…` のように、対象と期待する動作を示します。SwiftData や画面を操作するテストは既存の `@MainActor` の使い方に合わせてください。

数値によるカバレッジ基準はありません。解析・暗号化・削除・復元の変更には、異常系と、保存形式 v1 が変わっていないことを確認する回帰テストを追加します。画面変更は通常幅・最小960×640で確認してください。

scheme の `XKEYS_TESTING=1` により、メモリ内ストア・一時ファイル・注入した鍵を使います。製品の Keychain、実データ、既存バックアップをテストや掃除で変更しないでください。

## コミット・Pull Request

履歴に合わせ、`feat(credentials): …`、`fix(backup): …`、`refactor(navigation): …`、`docs: …` の形式で、機能ごとにコミットを分けます。

PR には問題、変更後の動作、実行したテスト、未確認事項を記載します。関連 Issue があればリンクし、UI 変更には変更後の画面画像を添付してください。保存形式や署名を変える場合は、既存データへの影響も説明します。

## 秘密情報と保存形式

実際の鍵、証明書、パスワードをコミットしないでください。資格情報のメタデータは暗号化の AAD に含まれます。モデルや所属の変更では、既存ファイルの復号とバックアップ復元の互換性を確認してください。
