# リリース手順

Xkeys は Developer ID で署名・公証した DMG を、このリポジトリの GitHub Releases で配布します。ビルドから公開までは GitHub Actions（`.github/workflows/release.yml`）が行い、手元の Mac では配布しません。

Mac App Store には提出しません。Apple Developer 連携が非公開の Web API と Apple Account のログインを使うため、審査で却下される可能性が高いからです。

## バージョン

| 項目 | 形式 |
| --- | --- |
| `MARKETING_VERSION`（`CFBundleShortVersionString`） | `X.Y.Z`（セマンティックバージョニング）。リリースブランチ名から CI が設定する |
| `CURRENT_PROJECT_VERSION`（`CFBundleVersion`） | GitHub Actions の `run_number`。CI が設定する |
| リリースブランチ | `release/Ver_X.Y.Z` |
| Git タグ | `vX.Y.Z`（GitHub Release の作成時に付く） |
| DMG | `Xkeys-X.Y.Z.dmg` |

プロジェクトの `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` は手元のビルド用の値で、配布版には CI が上書きします。バックアップには `CFBundleShortVersionString` が `appVersion` として記録されます。

同じバージョンは出し直せません。公開済みのタグがあれば CI は止まるので、修正は次のバージョンで出します。

## 署名の構成

| 構成 | 署名 | プロファイル |
| --- | --- | --- |
| Debug | Apple Development（自動署名） | Xcode が管理 |
| Release | Developer ID Application（手動署名） | `Xkeys Developer ID` |

Release は手動署名に固定しています。Xkeys は `keychain-access-groups` を使うため、Developer ID 版にもプロファイルが必要です。手元で Release をビルドする場合は、Xcode の **Settings → Accounts → Download Manual Profiles** か `-allowProvisioningUpdates` で `Xkeys Developer ID` を取得してください。

## 事前準備（初回だけ）

Apple 側の資格情報は Xkeys 自身に登録して管理します。

1. **Developer ID Application 証明書**: 秘密鍵込みの .p12 を Xkeys の「鍵と証明書」に取り込み、パスワードも保存する。
2. **Developer ID プロファイル**: Apple Developer の Profiles で種類 **Developer ID**、App ID `com.yuuki.xkeys`、上の証明書を選び、名前を `Xkeys Developer ID` にして作成する。Xkeys のアプリ「Xkeys」で「Apple Developer から取り込む…」から保管する。Capabilities の追加は不要。
3. **App Store Connect API キー**: 公証に使う。App Store Connect の **ユーザとアクセス → 統合 → App Store Connect API** のチームキー（Developer 以上）を、用途「App Store Connect API」で Xkeys に取り込み、Issuer ID も入力する。
4. **GitHub Secrets**: Xkeys のアプリ「Xkeys」で「CI 用の Secret ファイルを作成…」を開き、.env を書き出して **Settings → Secrets and variables → Actions** に登録する。登録後は .env を削除する。

| Secret | 内容 |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | Developer ID Application の .p12 |
| `P12_PASSWORD` | .p12 のパスワード |
| `BUILD_PROVISION_PROFILE_BASE64` | `Xkeys Developer ID` プロファイル |
| `ASC_KEY_P8_BASE64` | App Store Connect API キーの .p8 |
| `ASC_KEY_ID` | API キーの Key ID |
| `ASC_ISSUER_ID` | API キーの Issuer ID |

Xkeys が出力する `APPLE_TEAM_ID` は登録しても構いませんが、ワークフローでは使いません。CI 上の一時キーチェーンのパスワードは毎回ランダムに作ります。

## リリース

1. `main` から `release/Ver_X.Y.Z` ブランチを作る。
2. `CHANGELOG.md` の `## [Unreleased]` を `## [X.Y.Z] — YYYY-MM-DD` に変え、その上に空の `## [Unreleased]` を残してコミットする。この節がリリースノートになる。
3. ブランチを push する。

```sh
git switch -c release/Ver_0.1.0
# CHANGELOG.md を編集してコミット
git push origin release/Ver_0.1.0
```

4. Actions の **Release** が成功すると、`vX.Y.Z` の GitHub Release に DMG が添付される。
5. リリースブランチを `main` にマージし、CHANGELOG の変更を戻す。

## CI が行うこと

1. ブランチ名からバージョンを取り出し、公開済みでないことと CHANGELOG の節を確認する
2. 必要な Secrets が揃っているか確認する（欠けていれば署名前に止める）
3. Swift 6.4 を確認し、署名なしでテストを実行する
4. .p12 を一時キーチェーンに、プロファイルを Xcode のプロファイル置き場に入れる
5. Release を archive し、`ExportOptions.plist`（developer-id・手動署名）で export する
6. .app を zip にして公証し（`scripts/notarize.sh`）、staple する
7. .app と `/Applications` へのリンクを入れた DMG を作り、Developer ID で署名・公証・staple する
8. `spctl` で Gatekeeper の判定を確認する
9. GitHub Release を作って DMG を添付する
10. 成否にかかわらず一時キーチェーン・プロファイル・.p8 を削除する

公証に失敗した場合は、Actions のログに Apple の判定結果（`notarytool log`）が出ます。

## 手元での確認

公開後、DMG をダウンロードして別ユーザーまたは別の Mac で次を確認します。

```sh
xcrun stapler validate Xkeys-X.Y.Z.dmg
spctl -a -t open --context context:primary-signature -vv Xkeys-X.Y.Z.dmg
```

インストールしたアプリが起動すること、Touch ID で保存できること、再起動後に復号できることも確かめます。
