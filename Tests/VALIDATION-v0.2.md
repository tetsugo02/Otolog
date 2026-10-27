# Otolog 0.2.0 検証記録

実施日：2026-10-27．環境：macOS 27.0.1／arm64，Xcode 27.1，macOS 27 SDK．最小対応OSはmacOS 15です．

## 実行した確認

```sh
xcodebuild -project Otolog.xcodeproj -scheme Otolog -configuration Debug -derivedDataPath build build
./Scripts/test.sh
codesign --verify --deep --strict build/Build/Products/Release/Otolog.app
plutil -lint Otolog/Info.plist Otolog/Otolog.entitlements Otolog.xcodeproj/project.pbxproj
lipo -archs build/Build/Products/Release/Otolog.app/Contents/MacOS/Otolog
```

Debug／Releaseとも`BUILD SUCCEEDED`．arm64／x86_64の両方をビルドしました．署名検証，plist検証も成功しました．Swiftのコンパイル警告・エラーはありません．AppIntents未使用に伴うXcodeのメタデータ抽出警告が1件あります．x86_64での実行は未実施です．

`./Scripts/test.sh`は以下の結果で終了しました．録音機器の実音声や会議への参加は使わず，合成入力と純粋な判定ロジックを検証しています．

```text
PASS: timeline, drift, gaps, mixing, conversion, ALAC segments, export/reload, recovery, microphone mode, meeting detection, JST names, rename safety
```

| 確認項目 | 結果 |
| --- | --- |
| マイクのみ設定 | 再生音声を取得せず，選択マイクの録音が有効になることを確認 |
| マイクのみの形式変換・ALAC保存・AAC出力 | 合成24 kHzモノラルを使用し，48 kHz・2 ch・正確に48,000フレームの完成音声を再読み込み |
| マイクのみの音量・左右 | 等倍の音量と中央配置を完成AACで確認 |
| 開始オフセット，無音ギャップ，到着順，遅着 | 成功 |
| 再生停止後の再開 | 古い保留パケットが遅着エラーを起こさず，空白を保って再開 |
| Aggregateの開始条件 | 再生開始を待つフラグがfalseであることを確認 |
| PCM未到着／受信／休止 | 未到着を許可拒否と断定しない状態判定を確認 |
| 2音源の混合，モノラルの中央配置 | クリップ回避とマイクのバッファー除去を確認 |
| +100 ppm，1時間相当の合成時計ずれ | ホスト時間と一致し，端点にも欠落なし |
| 48パケットの処理待ち上限 | 超過を明示的に通知 |
| 24 kHzモノラル／44.1 kHzステレオの変換 | 左右と音量を確認 |
| 31秒の分割ALAC→AAC | 正確に1,488,000フレーム，分割境界の音量も確認 |
| 保存失敗・壊れたセグメントの回復 | 元データと警告を保持 |
| Zoom・Teams・Google Meetの候補判定 | 合成プロセス情報・タイトルを与えて判定を確認 |
| 誤検知抑制 | アプリの起動だけでは通知せず，一時的な入力利用と重複通知，録音中の通知を抑止 |
| JSTの既定名 | UTC 2026-10-26 18:04:05が2026-10-27_03-04-05_JSTになることを確認 |
| 回復用の日時保持・同名対策 | 開始日時をJSONへ保持し，同名には (2)を追加 |
| 名前変更 | 既存ファイルを拒否し元音声・既存内容を保持，変更後も31秒の音声を再読み込み |
| 通知の描画 | 実際のSwiftUI通知ビューを画像へ描画し，テキスト・録音開始ボタンの収まりを目視確認 |

## 確認用成果物

- `build/Validation/meeting-prompt.png`：実際の通知ビューのオフスクリーン描画．
- `build/Validation/31-second-sample.m4a`：31秒の合成440 Hz音声．
- `build/Validation/microphone-only-sample.m4a`：マイクのみ経路を使った1秒の合成音声．
- `build/Validation/otolog-debug-build.log`：Debugビルドログ．
- `build/Validation/otolog-release-and-tests.log`：Releaseビルドとテストのログ．
- `build/Validation/audio-format.txt`と`microphone-format.txt`：afinfoによる独立した形式確認．

## 未検証事項

- 実際のZoom／Teams／ブラウザーMeetによる検知，通知位置・30秒での非表示・フォーカス・録音開始ボタンのデスクトップ上での操作は未検証です．SwiftUI画像の描画確認は，実ウインドウの操作確認とは区別します．
- ブラウザーの会議名確認に使うアクセシビリティ許可は実際には操作・付与していません．許可なしの場合の一般的なブラウザー候補へのフォールバックは判定ロジックで確認しています．
- 実マイク入力，Tap受信，AirPodsとの同時利用，切断・再接続，長時間の実デバイス同期・メモリーは未検証です．1時間相当の合成試験は実時間1時間の試験ではありません．
- 保存名ダイアログの実クリック・キャンセル操作は未検証です．JSTの生成，ファイル名の衝突，移動先の上書き拒否，変更後の音声は自動検証しています．
- macOS 15／26での実行，AirPods高音質モードとZoomの同時利用は未検証です．

READMEに追加機能と従来のAirPods試験の手順を記載しました．実行中の旧MeetingRecorder／Otologを終了してから，新しい`build/Build/Products/Release/Otolog.app`を起動してください．bundle IDと既存の保存先は互換性のため維持しています．

## ドキュメントの更新

従来のREADMEにあった「会議検知を行わない」「完成名にランダムIDを含む」という記述を，新しい実装へ合わせて更新しました．マイクのみの場合の等倍音量，待機中のメタデータ照会，任意のアクセシビリティ許可も追記しました．以前の4秒未受信による停止と，現在の相手側入力待ち表示も区別しています．

[初版の検証記録](VALIDATION-v0.1.md)は旧名称・旧パスを含む履歴として保存しています．
