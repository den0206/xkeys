<p align="center">
  <img src="Xkeys/Resources/DesignAssets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" alt="Xkeys">
</p>

# Xkeys

[![Release](https://github.com/den0206/xkeys/actions/workflows/release.yml/badge.svg)](https://github.com/den0206/xkeys/actions/workflows/release.yml)

[English](README.md) | **日本語**

Apple開発者向けの鍵・証明書・プロビジョニングプロファイル管理アプリです。チーム・アプリ・ターゲットごとに整理し、元ファイルをMacに暗号化して保存します。期限はアプリの一覧とDockバッジで確認できます。

## 対応環境

- macOS 26.0以降
- チームの登録・オンライン取り込みにはApple Developerのチームへの所属が必要
- 開発環境：Xcode 27.0 / Swift 6.4、Apple Development署名

## インストール

配布先は[このリポジトリのGitHub Releases](https://github.com/den0206/xkeys/releases)です。リリースが公開されたら `Xkeys-X.Y.Z.dmg` をダウンロードして開き、`Xkeys.app` を `/Applications` に移動してください。

リリースワークフローでDeveloper ID署名とDMGの公証を行います。Mac App Storeでは配布しません。

## 主な機能

- `.p8`・`.cer`・`.p12`・`.mobileprovision`・`.provisionprofile`の取り込み、一括取り込み
- Apple Developerへのログイン、所属チームの登録、証明書・プロファイルのダウンロード
- 本体・拡張・Widgetなど、Bundle IDが異なるターゲットをアプリ単位で管理
- 期限の一覧、チームを横断する検索、種類による絞り込み
- 暗号化メモ、任意の`.p12`パスワード保存
- 認証後の値のコピー、元形式での書き出し
- CI用Secretファイルの`.env`形式での書き出し
- 削除した項目の30日間の復元
- パスワード保護付きバックアップ、競合を確認して復元
- OSの言語設定に応じた日本語・英語表示

最初にApple Developerへログインして所属チームを選び、アプリを登録してファイルを取り込みます。鍵・証明書はチーム内で共有し、プロファイルは各アプリのターゲットに保管します。

詳しい手順は[操作ガイド](docs/USAGE.md)を参照してください。

## プライバシーとセキュリティ

- 元ファイル・メモ・保存済みの`.p12`パスワードは、AES-GCMでこのMacに暗号化保存します。暗号鍵は端末専用のKeychainに保存します。名前・識別子・期限などのメタデータは、別途SwiftDataに保存します。
- 秘密情報の操作にはTouch IDまたはMacのパスワードで認証が必要です。iCloud同期・自動起動は行いません。
- Apple Developer認証には[XcodesLoginKit](https://github.com/XcodesOrg/XcodesLoginKit)を使用します。Apple Accountのパスワード・確認コードは保存しません。セッションCookieはこのMacのKeychainに保存し、ログアウト時に削除します。
- ログイン・所属確認・オンライン取り込み・鍵の用途取得時に、Apple（`idmsa.apple.com`・`developer.apple.com`・`appstoreconnect.apple.com`）へ通信します。解析・広告・トラッキングの仕組みはありません。
- 書き出した元ファイル・保護なしのバックアップ・CI用`.env`は、金庫の暗号化保護の対象外です。バックアップは安全な場所で保管し、CIへ登録したSecretファイルは削除してください。

オンライン連携はAppleの非公開Web APIに依存し、Apple側の変更への対応が必要になる場合があります。信頼済み端末・SMSの確認コードに対応します。フェデレーション認証・セキュリティキーには対応しません。ダウンロード済みの`.p8`や証明書の秘密鍵は取得できません。オンラインでの失効確認は行いません。

未登録チームを含むバックアップの復元には、すべての対象チームへの所属確認が必要です。脱退などで確認できない場合は復元できません。登録済みチームだけならオフラインで復元できます。

詳しくは[仕様と保存形式](docs/DESIGN.md)を参照してください。

## 開発

### Xcode

`Xkeys.xcodeproj` を開き、scheme **Xkeys**、実行先 **My Mac** で実行します。**Signing & Capabilities** で **Xkeys** と **XkeysTests** に利用できるTeamを設定し、Keychain Sharingの専用グループを確認してください。秘密情報の保管にはApple Development署名が必要です。アドホック署名では使えません。

### VS Code / Cursor

1. 推奨拡張機能の **CodeLLDB** をインストールします。
2. リポジトリのルートを開きます。
3. 「実行とデバッグ」で **Run Xkeys Debug.app** を選び、**F5** を押します。

Debug版は **Xkeys Dev** という名前で、配布版とはコンテナ・暗号鍵を共有しません。

### コマンドライン

```sh
xcodebuild -project Xkeys.xcodeproj -scheme Xkeys \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/xcode build

xcodebuild -project Xkeys.xcodeproj -scheme Xkeys \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/xkeys-tests test
```

テストはschemeの `XKEYS_TESTING=1` により、メモリ内ストア・一時ファイル・注入した鍵を使います。製品の資格情報や既存バックアップをテストに使わないでください。

署名エラーへの対処と確認範囲は[開発ガイド](docs/IMPLEMENTATION.md)を参照してください。

## リリース

`release/Ver_X.Y.Z` ブランチをpushすると、Releaseワークフローがバージョン・リリースノート・必要なSecretsを確認し、テスト、アプリとDMGのビルド・署名、DMGの公証、GitHub Releasesへの公開を行います。公開後、`main` の `CHANGELOG.md` にある英語の `[Unreleased]` をリリースしたバージョンの節へ移します。

配布はGitHub Actionsから行います。署名用の資格情報はGitHub Actions Secretsに登録し、値や書き出した`.env`をコミットしないでください。

詳しくは[リリース手順](docs/RELEASE.md)を参照してください。

## ドキュメント

以下のガイドは日本語、変更履歴は英語です。

- [操作ガイド](docs/USAGE.md)
- [仕様と保存形式](docs/DESIGN.md)
- [開発と確認状況](docs/IMPLEMENTATION.md)
- [リリース手順](docs/RELEASE.md)
- [ドキュメントの公開前確認](docs/SECURITY_REVIEW.md)
- [変更履歴](CHANGELOG.md)

## プロジェクト構成

```text
Xkeys/Application/      起動・ウィンドウ構成
Xkeys/Features/         画面と操作
Xkeys/Models/           チーム・アプリ・登録時の検証
Xkeys/Services/         解析・認証・検索・設定
Xkeys/Persistence/      暗号化保存・バックアップ・復元
Xkeys/Resources/        画像・翻訳
XkeysTests/             XCTest・架空データ
scripts/                公証スクリプト
.github/workflows/      リリースワークフロー
docs/                   操作・設計・開発・配布の文書
```

## 確認状況

確認済みの範囲と残る実機確認は[開発ガイド](docs/IMPLEMENTATION.md)に記載しています。製品画面の全操作を確認したことは意味しません。

## ライセンス

このリポジトリの独自コードには、現在ライセンスが設定されていません。公開されていることだけを理由に、再利用・再配布が許可されるわけではありません。依存ライブラリには、それぞれのライセンスが適用されます。
