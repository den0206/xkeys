# 解析用fixture

すべてこのプロジェクト用に生成した架空のテストデータ。Appleの署名・実アプリの証明書ではありません。

- sample.mobileprovision: 自己署名証明書でCMS署名したplist。期限2030-01-01 UTC、Team TESTTEAM01。
- sample.cer: 同じ自己署名証明書のDER表現。
- renewed.cer: 更新時の置き換え検証用の別の自己署名証明書。公開証明書のみを保持し、生成用秘密鍵は削除済み。
- chain.p12: 架空のリーフ証明書・発行元証明書2件とテスト秘密鍵。候補選択の検証用。SecItemImportと互換性のあるOpenSSLのlegacy形式。パスワードは `fixture-only`。
- sample.p12: 上のテスト証明書と生成したテスト秘密鍵。パスワードは `fixture-only`。

.p12内の鍵はテスト専用であり、署名・配布や本データの保護には使用しません。生成に使ったPEM秘密鍵は保存していません。アプリに含めるのは公開情報だけのsample.mobileprovisionです。

- empty-v1.appmatebackup: v1の保護なしバックアップ。2001-01-01 UTC作成扱い、Team/App/資格情報0件。保存形式の互換性確認用で、秘密情報は含まない。
