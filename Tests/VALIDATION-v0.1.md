# 初版MeetingRecorderの検証記録（旧名称の履歴）

実施日：2026-10-27．

## 環境とビルド

- 実行環境：macOS 27.0.1（26A434），arm64．
- Xcode：27.1（27A9275）．利用SDK：macOS 27.0．
- 最小対応OS：macOS 15.0．
- Xcodeライセンス・初期設定：当初未完了だったためユーザーが実施し，`xcodebuild -checkFirstLaunchStatus`の成功を確認しました．
- Debug／Release：両方`BUILD SUCCEEDED`．arm64／x86_64のUniversal Binaryを生成しました．x86_64での実行は未実施です．
- `codesign --verify --deep --strict`：成功．ローカルad-hoc署名です．配布用の公証ではありません．
- Info.plist，entitlements，project.pbxprojの`plutil -lint`：成功．
- Swiftコードのコンパイルエラー・警告：なし．XcodeのAppIntentsメタデータ抽出で，該当Frameworkを使っていない旨の警告が1件出ます．

コマンド：

```sh
xcodebuild -project MeetingRecorder.xcodeproj -scheme MeetingRecorder -configuration Debug -derivedDataPath build build
xcodebuild -project MeetingRecorder.xcodeproj -scheme MeetingRecorder -configuration Release -derivedDataPath build build
/usr/bin/time -l build/Build/Products/Release/MeetingRecorder.app/Contents/MacOS/MeetingRecorder --self-test
codesign --verify --deep --strict build/Build/Products/Release/MeetingRecorder.app
```

## 自動検証結果

`PASS: timeline, drift, gaps, mixing, conversion, ALAC segments, export/reload, recovery`．最終実行は約4.38秒，最大RSSは112,705,536 bytesでした．これはGUIランタイムを含む合成テストプロセスの数値であり，会議中や1時間実録音の計測値ではありません．

| 対象 | 結果 |
| --- | --- |
| 開始オフセット，無音ギャップ，遅着パケット検出 | 成功 |
| 音源間のコールバック到着順の違い | 同一の混合結果 |
| 2音源のフルスケール混合 | 最大1.0，通常加算クリップなし |
| モノラルの左右中央配置 | 成功 |
| マイクのバッファー除去 | 相手側を残してマイクだけ除去 |
| +100 ppm，1時間相当の合成時計ずれ | ホスト時間3600.36秒と一致，パケット端点も欠落なし |
| 固定リングと48パケット上限 | 超過をエラー通知 |
| 実AVAudioConverter：24 kHzモノラル | 48 kHzへ変換し，左右・レベルを確認 |
| 実AVAudioConverter：44.1 kHzステレオ | 左右の独立性と変換後レベルを確認 |
| 31秒のALACセグメント→完成AAC | 正確に1,488,000フレーム |
| 30秒の分割境界 | 前後の短区間RMSに無音・音量ジャンプなし |
| 全完成ファイルのデコード | 元フレーム数と一致 |
| 保存先へ書き込み不可 | 保存失敗を検出し，元CAFを保持 |
| 壊れたセグメントを含む回復 | 読めた音声を保存し，警告と元フォルダーを保持 |

`afinfo`でも完成ファイルを独立して確認しました．

```text
File type ID: m4af
Data format: 2 ch, 48000 Hz, aac
estimated duration: 31.000000 sec
bit rate: 191973 bits per second
1488000 valid frames
```

確認用の合成440 Hz音声は`build/Validation/31-second-sample.m4a`です．ビルドログ，テストログ，afinfoの結果も`build/Validation/`に保存しています．

## 起動確認と未検証事項

- `open`で開発中のReleaseアプリを起動し，プロセスが継続動作することを確認しました．最新の実行ファイルも`--self-test`として起動成功しています．
- ネイティブUIの自動操作は環境で許可されなかったため，メニューバーUIの視覚確認・クリック操作は未実施です．権限設定の操作は行っていません．
- マイクやTapからの実音声取得は未検証です．Zoom／Teams／MeetとAirPodsを使った実録音，実際の切断・再接続，録音中のミュート切り替え，通常終了抑止のUI操作確認はREADMEの手動テストで確認してください．
- 1時間相当の時計ずれテストは加速した合成入力です．1時間の実機音ずれ・CPU・メモリー安定性を確認したという意味ではありません．
- macOS 15／26の実行，AirPods高音質モードとZoomの同時使用は未検証です．
- 実ボリュームを満杯にする試験，電源断試験は行っていません．録音中の空き容量監視と，保存失敗時の回復データ保持を実装しています．

## 保存方式の判断

分割AACのパススルーでは，M4A直接出力が`AVFoundationErrorDomain -11838`／`NSOSStatusErrorDomain -16976`で失敗しました．MPEG-4経由では31秒が31.06秒としてCore Audioで再読み込みされました．そのためALAC分割→単一AAC変換へ変更し，厳密なフレーム数一致を合格条件にしています．AACを二重圧縮せず，回復性を維持する一方，回復用容量と停止時の変換処理が必要です．

作業開始時に既存プロジェクト・コード・ドキュメントはありませんでした．既存作業の上書きや，既存ドキュメントとの不一致はありません．
