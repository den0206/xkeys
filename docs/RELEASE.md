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

リリースノートは `CHANGELOG.md` の `## [Unreleased]` から自動で作ります。利用者に見える変更は、開発中に `[Unreleased]` へ英語で書いておきます。

1. `main` から `release/Ver_X.Y.Z` ブランチを作り、push する。

```sh
git switch -c release/Ver_0.1.0
git push origin release/Ver_0.1.0
```

2. Actions の **Release**（check → build → publish）が成功すると、`vX.Y.Z` の GitHub Release に DMG が添付される。ノートは `[Unreleased]` の内容。
3. 続けて CI が `main` の `CHANGELOG.md` で `[Unreleased]` の内容を `## [X.Y.Z] — YYYY-MM-DD` の下に移し、`Casks/xkeys.rb` の `version` と `sha256` を DMG に合わせて書き換え、両方を `[skip ci]` 付きの1コミットにまとめる。

`[Unreleased]` が空なら CI は最初に止まります。リリースブランチを作ったあとに `main` の `[Unreleased]` へ追記した項目も、`main` 側ではこのバージョンの節に入るので、必要なら手で直してください。`main` に保護ルールを設定する場合は、`github-actions[bot]` の push を許可してください。

## CI が行うこと

macOS の実行時間は Linux より高く数えられるため、macOS で動かすのはテスト・署名・公証・staple だけにしています。

| ジョブ | ランナー | 時間上限 | 内容 |
| --- | --- | --- | --- |
| check | Ubuntu | 5分 | ブランチ名からバージョンを取り出し、公開済みでないこと・`[Unreleased]` に内容があること・Secrets が揃っていることを確認する。失敗すれば macOS は起動しない |
| build | macOS | 40分 | 署名なしでテスト → .p12 とプロファイルを一時キーチェーン等に入れる → archive・export（developer-id・手動署名） → DMG を作って Developer ID で署名 → DMG を1回だけ公証して staple → DMG を artifact に保存 → 成否にかかわらず一時キーチェーン・プロファイル・.p8 を削除 |
| publish | Ubuntu | 10分 | GitHub Release を作って DMG を添付し、`main` の CHANGELOG で `[Unreleased]` を `[X.Y.Z]` の節に移し、Homebrew の Cask を更新してコミットする |

- 公証は DMG だけに行います。中のアプリも同じ提出で公証されますが、チケットを staple するのは DMG だけです。DMG からコピーしたアプリを初めて開くときは、Gatekeeper がオンラインで公証を確認します。
- 公証の待ち時間は15分まで（`scripts/notarize.sh`）です。Apple 側が混んで15分を超えたときや、却下されたときはジョブを失敗にし、Actions のログに Apple の判定（`notarytool log`）を出します。
- 各ステップに時間上限があり、超えたりキャンセルしたりするとジョブは失敗します。GitHub Release は publish でしか作らないので、途中で止まっても中途半端なリリースは残りません。
- 同じリリースブランチに新しく push すると、古い実行の check・build は取り消され、新しい実行だけが続きます。publish はすでに始まっていれば最後まで続けます（Release の作成と CHANGELOG の反映を途中で止めないため）。その場合、古いコミットが先に公開されるので、新しい実行は check の「公開済み」で止まります。修正は次のバージョンで出してください。
- publish だけが失敗した場合は、Actions の「Re-run failed jobs」で publish だけをやり直せます。macOS で再ビルドはしません（DMG の artifact は3日間保存）。作成済みの Release や反映済みの CHANGELOG があれば、その処理は飛ばします。

## Homebrew

このリポジトリ自身を tap として使い、Cask は `Casks/xkeys.rb` に置きます。利用者は次のコマンドでインストールします。

```sh
brew tap den0206/xkeys https://github.com/den0206/xkeys
brew trust --cask den0206/xkeys/xkeys
brew install --cask xkeys
```

- Homebrew は公式以外の tap の Cask を `brew trust` するまで読み込みません（`Refusing to load cask ... from untrusted tap`）。手順には Cask だけを信頼する `brew trust --cask` を載せます。
- Homebrew は認証なしで DMG を取得するため、リポジトリが Private のあいだはインストールできません。
- リリースのたびに、CI が `version` と `sha256` の2行だけを書き換えます。そのほかの定義（`url`、`depends_on`、`zap` など）を変えるときは `Casks/xkeys.rb` を直接編集し、`brew audit --cask --strict` と `brew style` で確認します。Homebrew は tap 内の Cask しか検査しないため、`brew tap-new --no-git` で作った一時 tap にコピーして実行し、終わったら `brew untap` します。
- `zap` は App Sandbox のコンテナ `~/Library/Containers/com.yuuki.xkeys` を丸ごと削除します（暗号化した保管庫を含む）。Keychain の暗号鍵と Apple Developer の Cookie は Cask から削除できないので残ります。
- 公式の homebrew/cask へ移す場合は、notability の基準（Star 数など）を満たしてから申請します。

## 手元での確認

公開後、DMG をダウンロードして別ユーザーまたは別の Mac で次を確認します。

```sh
xcrun stapler validate Xkeys-X.Y.Z.dmg
spctl -a -t open --context context:primary-signature -vv Xkeys-X.Y.Z.dmg
```

インストールしたアプリが起動すること、Touch ID で保存できること、再起動後に復号できることも確かめます。
