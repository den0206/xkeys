# Repository Guidelines

## プロジェクト構成

App Mate は macOS 26.0 以降向けの SwiftUI・SwiftData アプリです。Apple Developer認証にはXcodesLoginKitを使用します。それ以外の外部ライブラリ追加は必要性を確認してください。

- `AppMate/Application/`：起動とウィンドウ構成。
- `AppMate/Features/`：一覧、取り込み、設定、バックアップなどの画面。
- `AppMate/Models/`：チーム・アプリのモデルと登録時の検証。
- `AppMate/Services/`：解析、認証、検索、設定。
- `AppMate/Persistence/`：暗号化保存、変更履歴、バックアップ・復元。
- `AppMate/Resources/`：画像アセットと同梱リソース。
- `AppMateTests/`：XCTest と架空データの `Fixtures/`。
- `docs/DESIGN.md`：動作仕様。`docs/IMPLEMENTATION.md`：開発手順と確認範囲。

## ビルド・実行

開発環境は Xcode 27.0・Swift 6.4、scheme は `AppMate` です。

```sh
# 通常の Debug ビルド
xcodebuild -project AppMate.xcodeproj -scheme AppMate \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/xcode build

# 通常ビルドと出力先を分けてテスト
xcodebuild -project AppMate.xcodeproj -scheme AppMate \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/app-mate-tests test
```

テストは `AppMateTests/AppMateTests.swift` の `AppMateTests` クラスにまとまっています。1件だけ実行する場合は `test` の前に `-only-testing:AppMateTests/AppMateTests/testName` を付けます。

実行は Xcode の `My Mac`、または CodeLLDB を導入した VS Code / Cursor の F5 を使います。秘密情報の操作には Apple Development 署名が必要です。両ターゲットの Team を合わせ、署名設定は README に従ってください。

## アーキテクチャの要点

- 起動は `Application/AppMateApp.swift`。`APP_MATE_TESTING=1` ならメモリ内の `ModelContainer` を使います。SwiftData のモデルを追加したら、ここの型一覧にも追加してください。
- メタデータ（`DeveloperTeam`・`ManagedApp`・`StoredCredential`）は SwiftData に保存します。元ファイル・メモ・.p12 パスワードは `CredentialPayload` として AES-GCM で暗号化し、`AppMateVault/blobs` に保存します。鍵は端末専用 Keychain（`EncryptionKeychain`）にあります。
- 暗号化 blob の AAD は `StoredCredential.authenticatedData()`（metadataVersion 1 / 2）と `VaultManagement.noteAAD` で作ります。AAD に含まれる項目（kind、所属、`keyPurpose` など）は自動で書き換えないでください。変えるときは別 UUID の blob に暗号化し直し、読み戻して検証してから参照を切り替えます（`VaultManagement.updatePurposes` を参照）。
- 取り込みは `CredentialVault`（`validate` → `importFile`）、編集・削除・復元・完全削除は `VaultManagement` が担当します。秘密情報の操作は `OwnerAuthentication` で毎回認証し、取得した `SymmetricKey` を渡します。
- データを変更する処理は、変更の前に `BackupHistory.prepare` を、変更時に `BackupHistory.record` を同じ context で呼び、未バックアップ件数を記録します。バックアップ形式は `BackupArchive`（`BackupSnapshot`、旧 version 1 / 2 も読み込む）、復元は `BackupRestore` / `RestorePlan` です。
- Apple Developer 連携は `AppleDeveloperSession`（XcodesLoginKit、Cookie を Keychain に保存）と `AppleDeveloperClient`（非公開の Web API、応答サイズ・件数を検証）が担当します。HTTP と Keychain はテストで架空のものに差し替えます。
- `VerificationRecord` は削除済みの技術検証画面が使っていた SwiftData モデルです。既存ストアを開くために型一覧に残しています。
- 仕様を変えたら `docs/DESIGN.md`、確認範囲を変えたら `docs/IMPLEMENTATION.md`、操作を変えたら `README.md` も更新します。

## コーディング規約

既存コードに合わせ、インデントはスペース4個、型名は `UpperCamelCase`、関数・変数名は `lowerCamelCase` にします。ファイル名は主要な型や機能に合わせます。画面は `Features/`、保存処理は `Persistence/` に置き、同じ処理を画面ごとに複製しないでください。

UI 文言は日本語にし、既存の `AppMateStyle` と標準コントロールを使います。専用の formatter・linter 設定はありません。変更後は `git diff --check` で空白の問題を確認してください。

## テスト方針

テスト名は `testTeamScopeIncludesAllSharedFormats…` のように、対象と期待する動作を示します。SwiftData や画面を操作するテストは既存の `@MainActor` の使い方に合わせてください。

数値によるカバレッジ基準はありません。解析・暗号化・削除・復元の変更には、異常系と旧形式の互換性を確認する回帰テストを追加します。画面変更は通常幅・最小960×640で確認してください。

scheme の `APP_MATE_TESTING=1` により、メモリ内ストア・一時ファイル・注入した鍵を使います。製品の Keychain、実データ、既存バックアップをテストや掃除で変更しないでください。

## コミット・Pull Request

履歴に合わせ、`feat(credentials): …`、`fix(backup): …`、`refactor(navigation): …`、`docs: …` の形式で、機能ごとにコミットを分けます。

PR には問題、変更後の動作、実行したテスト、未確認事項を記載します。関連 Issue があればリンクし、UI 変更には変更後の画面画像を添付してください。保存形式や署名を変える場合は、既存データへの影響も説明します。

## 秘密情報と保存形式

実際の鍵、証明書、パスワードをコミットしないでください。資格情報のメタデータは暗号化の AAD に含まれます。モデルや所属の変更では、既存ファイルの復号とバックアップ復元の互換性を確認してください。
