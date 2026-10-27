# CIとRelease

[READMEへ戻る](../README.md)

## CI

`.github/workflows/ci.yml`は，mainへのpush，Pull Request，手動実行で動きます．Releaseワークフローからも同じ確認を呼び出します．

| ランナー | 実行環境 | ツールチェーン |
| --- | --- | --- |
| `macos-15` | Apple Silicon／arm64 | Xcode 16.4 |
| `macos-15-intel` | Intel／x86_64 | Xcode 16.4 |

IntelのGitHubホストランナーはMetal描画時にアサーションで終了するため，`OTOLOG_SKIP_UI_SNAPSHOTS=1`でUI画像の生成だけを省略します．音声・保存・回復などのテストは省略しません．UI描画はApple Silicon側で実行します．

両方でReleaseのバージョン検証テスト，Debugビルド，Releaseビルド，実アプリの`--self-test`を実行します．Releaseアプリにarm64とx86_64が含まれること，ad-hoc署名の整合性も確認します．診断ログはActionsのArtifactsに7日間保持します．

CIは音声の合成入力を使います．Zoom／Teams／Meetへの参加，録音許可の操作，AirPodsの実録音品質は確認しません．

## Releaseの仕組み

`.github/workflows/release.yml`は次の順で動きます．

1. CIと同じApple Silicon／Intelのチェックを実行します．
2. タグと`Otolog/Info.plist`のバージョンを照合します．
3. Universal版をビルドし，署名とアーキテクチャを確認します．
4. `Otolog-<version>-universal.zip`と`SHA256SUMS.txt`を作成し，ActionsのArtifactsへ14日間保持します．
5. **タグで実行された場合だけ**，ZIPとチェックサムを添付したGitHub Pre-releaseを作成します．

現在の配布物はad-hoc署名です．Developer ID署名・Appleの公証は設定していません．そのため全タグを開発用Pre-releaseとして公開し，通常版のLatestには設定しません．macOSの保護機能で起動できない場合があり，ソースからのローカルビルドも利用できます．署名済み・公証済みの配布に移行する場合は，別途Developer IDと公証の設定が必要です．

追加のSecretsは不要です．公開ジョブだけが自動発行の`GITHUB_TOKEN`に`contents: write`を付与します．ビルド・テストジョブはread-onlyで，checkout時の認証情報も残しません．公式ActionsはリリースのコミットSHAで固定しています．

## 公開せずにテストする

GitHubのActions → Release → Run workflowで，**mainブランチ**を選びます．CLIでも実行できます．

```sh
gh workflow run release.yml --ref main
```

CI・ZIP作成・チェックサム検証まで実行しますが，タグではないため公開ジョブはスキップされます．成果物はその実行のArtifactsからダウンロードできます．タグを選んで手動実行した場合は公開対象になるので，公開せず試すときはmainを選んでください．

## バージョンを公開する

次は0.4.0を公開する場合の例です．アプリのバージョンとビルド番号を更新し，mainのCIが成功したことを確認してからタグをpushします．

```sh
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.4.0' Otolog/Info.plist
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 4' Otolog/Info.plist
git add Otolog/Info.plist
git commit -m 'Bump version to 0.4.0'
git push origin main
```

CI成功後：

```sh
git tag -a v0.4.0 -m 'Otolog 0.4.0'
git push origin v0.4.0
```

`v0.4.0-beta.1`などの接尾辞も利用できます．この場合もInfo.plistのアプリバージョンは`0.4.0`です．バージョン不一致，不正なタグ，ビルドやテストの失敗があれば公開しません．既存Releaseや添付ファイルを上書きする処理はありません．

## ローカルでパッケージを確認する

```sh
python3 Scripts/test-release.py
./Scripts/package.sh v0.3.0
cd dist
shasum -a 256 --check SHA256SUMS.txt
```

引数は現在のInfo.plistと一致するタグに置き換えてください．省略すると現在のアプリバージョンでパッケージを作ります．成果物の`dist/`はGitへ含めません．ZIPを展開すると，最上位に`Otolog.app`が入っています．

## 保守

- ランナーのXcodeを変更するときは，両アーキテクチャでのCI結果を確認してください．`macos-latest`へ暗黙的に依存しない構成です．
- Actionsを更新するときは公式リリースのコミットSHAも更新してください．
- 署名・公証を追加する場合も，PRでSecretsや公開権限を使わない構成を維持してください．

公式資料：[GitHubランナー一覧](https://github.com/actions/runner-images)，[macOS 15 Intelイメージ](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)，[macOS 15 arm64イメージ](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md)．
