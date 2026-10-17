# 解析用fixture

`developer-id-g2.cer`を除き、このプロジェクト用に生成した架空のテストデータ。実アプリの署名用証明書ではありません。

- developer-id-g2.cer: Apple公開のDeveloper ID G2中間CA証明書。CA属性による分類・Team確認不要・バックアップ往復の検証用。公開証明書のみで、秘密鍵は含みません。配布元：https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer

- sample.mobileprovision: 自己署名証明書でCMS署名したplist。期限2030-01-01 UTC、Team TESTTEAM01。
- sample.cer: 同じ自己署名証明書のDER表現。
- certs.mobileprovision: sample.mobileprovisionと同じ内容に、DeveloperCertificatesとしてsample.cer・renewed.cerを順に入れたplist。プロファイル内の証明書の読み取り検証用。別に生成した自己署名証明書でCMS署名し、生成用秘密鍵は削除済み。
- renewed.cer: 証明書更新時に新旧を保持する検証用の別の自己署名証明書。公開証明書のみを保持し、生成用秘密鍵は削除済み。
- chain.p12: 架空のリーフ証明書と発行元証明書の2件、リーフのテスト秘密鍵。候補選択の検証用。SecItemImportと互換性のあるPBE-SHA1-3DES・SHA-1 MAC形式。パスワードは `fixture-only`。
- sample.p12: 上のテスト証明書と生成したテスト秘密鍵。パスワードは `fixture-only`。

.p12内の鍵はテスト専用であり、署名・配布や本データの保護には使用しません。生成に使ったPEM秘密鍵は保存していません。アプリに含めるのは公開情報だけのsample.mobileprovisionです。

- empty-v1.xkeysbackup: v1の保護なしバックアップ。2001-01-01 UTC作成扱い、Team/App/資格情報0件。保存形式が意図せず変わっていないことの確認用で、秘密情報は含まない。
