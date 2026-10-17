# リリース手順

Xkeys は Developer ID で署名・公証した DMG を、このリポジトリの GitHub Releases で配布します。Mac App Store には提出しません（非公開の Apple Developer Web API を使うため）。

## バージョン

| 項目 | 形式 |
| --- | --- |
| `MARKETING_VERSION`（`CFBundleShortVersionString`） | `X.Y.Z`（セマンティックバージョニング） |
| `CURRENT_PROJECT_VERSION`（`CFBundleVersion`） | 整数。配布するビルドごとに1ずつ増やし、戻さない |
| リリースブランチ | `release/Ver_X.Y.Z` |
| Git タグ | `vX.Y.Z` |
| DMG | `Xkeys-X.Y.Z.dmg` |

どちらの値もプロジェクト全体の Build Settings に1か所だけ設定しています（Xcode の **Xkeys ターゲット → General → Identity** でも変更できます）。バックアップには `CFBundleShortVersionString` が `appVersion` として記録されます。

リリースノートは `CHANGELOG.md` の `[Unreleased]` に書き、リリース時に `[X.Y.Z] — YYYY-MM-DD` へ切り替えます。

## 事前準備（初回だけ）

Apple 側で発行した資格情報は、Xkeys 自身に登録して管理します。

1. Apple Developer の **Certificates** で **Developer ID Application** 証明書を作る（Account Holder だけが作れます）。Keychain Access から秘密鍵込みで .p12 を書き出し、Xkeys の「鍵と証明書」に取り込みます。
2. Xkeys の Release ビルドは `keychain-access-groups` を使うため、Developer ID プロファイルが必要です。export 時に Xcode が自動で作ります（`-allowProvisioningUpdates`）。作られたプロファイルは「Apple Developer から取り込む…」でアプリ「Xkeys」（`com.yuuki.xkeys`）に保管します。
3. App Store Connect の **ユーザとアクセス → 統合** で Team API キー（Developer ロール）を発行し、.p8 を用途「App Store Connect API」で Xkeys に取り込みます。Issuer ID も入力してください。
4. Xkeys から .p8 を書き出し、公証用のプロファイルを Keychain に保存します。保存したら .p8 ファイルは削除してください。

```sh
xcrun notarytool store-credentials xkeys-notary \
  --key AuthKey_<KEY_ID>.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
```

## リリース

```sh
VERSION=0.1.0
git switch -c release/Ver_$VERSION
# MARKETING_VERSION と CURRENT_PROJECT_VERSION を更新し、CHANGELOG.md の節を切り替えてコミット

OUT=.build/release
xcodebuild -project Xkeys.xcodeproj -scheme Xkeys -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath $OUT/dd \
  -archivePath $OUT/Xkeys.xcarchive archive -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath $OUT/Xkeys.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath $OUT/export -allowProvisioningUpdates

# .app を公証して staple
APP=$OUT/export/Xkeys.app
ditto -c -k --keepParent $APP $OUT/Xkeys.zip
xcrun notarytool submit $OUT/Xkeys.zip --keychain-profile xkeys-notary --wait
xcrun stapler staple $APP

# DMG を作り、署名・公証・staple
mkdir -p $OUT/dmg && cp -R $APP $OUT/dmg/ && ln -sf /Applications $OUT/dmg/Applications
DMG=$OUT/Xkeys-$VERSION.dmg
hdiutil create -volname "Xkeys $VERSION" -srcfolder $OUT/dmg -format UDZO -ov $DMG
codesign --force --timestamp --sign "Developer ID Application: Yuuki Sakai (4KJFNVZ8R6)" $DMG
xcrun notarytool submit $DMG --keychain-profile xkeys-notary --wait
xcrun stapler staple $DMG
```

公証に失敗した場合は `xcrun notarytool log <submission-id> --keychain-profile xkeys-notary` で理由を確認します。

## 確認

```sh
codesign --verify --strict --verbose=2 $APP
xcrun stapler validate $APP
xcrun stapler validate $DMG
spctl -a -vv $APP
spctl -a -t open --context context:primary-signature -vv $DMG
```

公開前に、DMG から別ユーザーまたは別の Mac へインストールし、起動・Touch ID での保存・再起動後の復号を確認します。

## 公開

```sh
git push origin release/Ver_$VERSION
git tag v$VERSION && git push origin v$VERSION
gh release create v$VERSION $DMG --title "Xkeys $VERSION" --notes-file <CHANGELOG の該当節>
```

最後に、リリースブランチの CHANGELOG を `main` に反映します。
