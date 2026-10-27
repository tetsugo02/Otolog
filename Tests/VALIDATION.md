# Otolog 0.3.0 検証記録

実施日：2026-10-27．macOS 27.0.1／arm64，Xcode 27.1／macOS 27 SDK．最小対応OSはmacOS 15です．

## ビルドと自動検証

```sh
xcodebuild -project Otolog.xcodeproj -scheme Otolog -configuration Debug -derivedDataPath build build
./Scripts/test.sh
codesign --verify --deep --strict build/Build/Products/Release/Otolog.app
plutil -lint Otolog/Info.plist Otolog.xcodeproj/project.pbxproj
```

Debug／Releaseとも`BUILD SUCCEEDED`，署名・plistの検証も成功しました．Swiftのエラー・警告はなく，XcodeのAppIntents未使用に関するメタデータ抽出警告が1件あります．arm64／x86_64の両方をビルドしています．x86_64での実行は未実施です．

```text
PASS: timeline, drift, gaps, mixing, conversion, ALAC segments, export/reload, recovery, microphone mode, meeting detection, JST names, rename safety, meeting titles, compact UI
```

追加した検証：

- Teamsの`プロダクト定例 | Microsoft Teams`，Meetの`設計レビュー - Google Meet - Google Chrome`，Zoomの`Zoom Meeting - Weekly Sync`から議題名を抽出しました．
- `Zoom Meeting`や`Zoom Workplace`など一般的なアプリ名を，議題名として使わないことを確認しました．これは合成タイトルでの検証であり，各アプリが実際に議題名を公開することを確認したものではありません．
- 録音名を回復用JSONに保存し，実際のALAC→AAC出力が`プロダクト定例.m4a`になることを確認しました．会議名のない旧形式のJSONも読めます．
- 空の名前や利用できない文字だけの名前はJST日時へ戻し，パス区切り文字を除去し，長いUnicode名をUTF-8で200バイト以内へ制限することを確認しました．
- 従来の同名連番，上書き拒否，変更後の再読み込み，時刻同期，混合，マイクのみの保存，回復，1時間相当の合成時計ずれの検証も通りました．

## デザイン確認

実際の`RecorderView`を非表示のNSWindow内で描画し，待機中・録音中・マイクのみのレイアウトを確認しました．ネイティブメニューとテキスト欄を含めて描画しています．デスクトップの撮影や他アプリの操作は行っていません．通知のSwiftUIビューも描画しています．

- [待機中のパネル](../docs/images/recorder.png)
- [録音中のパネル](../docs/images/recording.png)
- [マイクのみのパネル](../docs/images/microphone.png)
- [会議通知](../docs/images/meeting-prompt.png)

幅は460から360ポイントへ変更し，固定700ポイントの高さを廃止しました．設定を独立した画面に移し，メーターの形式情報はツールチップ，エラーの長い説明は詳細ポップオーバーへ移しました．マイクの状態，ミュートとの独立性，相手側入力待ち，保存結果は引き続きパネルに表示します．

初回検証時のビルドログと音声確認用ファイルは公開対象外です．再検証は`./Scripts/test.sh`で行い，音声や画像の生成先は実行結果の`Test artifacts:`を参照してください．

## 公開前の再検証

2026-10-28に`./Scripts/test.sh`を再実行し，Releaseの`BUILD SUCCEEDED`と上記全項目のPASSを確認しました．この再実行も合成入力による自動検証であり，実会議や実デバイスの確認ではありません．

## 手動確認が必要な項目

実際の会議名取得，アクセシビリティ許可，設定画面・メニューのクリック操作，実会議での通知と録音開始は未検証です．アプリが議題名をウインドウタイトルへ公開しない場合は取得できず，JST日時を使います．Meetではタイトルに会議コードしかない場合，コードを名前に使います．

実マイク，Tap，AirPods，切断・再接続，1時間の実機録音，macOS 15／26での実行は未検証です．従来と追加の手動テスト手順は[技術資料](../docs/TECHNICAL.md)にあります．

## ドキュメントの整合性

従来の「既定名は常にJST日時」「タイトルは保存しない」という説明は，新しい会議名優先の実装と合わなくなるため更新しました．取得した録音名はMac内の完成ファイル名と回復用JSONへ保存し，外部へ送信しません．旧パネルのボタン名と設定への導線も新UIへ合わせています．

[0.2.0の検証記録](VALIDATION-v0.2.md)と[初版の検証記録](VALIDATION-v0.1.md)は履歴として残しています．
