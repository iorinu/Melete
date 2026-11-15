# Melete リポジトリ案内

## 目的と対象

Melete は、筋力トレーニング等の種目・セット別の数値を記録する macOS アプリです。`project.yml` の deployment target は macOS 14.0 です。設計書にある将来機能を現行機能として扱わないでください。

## 主なファイル

- `project.yml`: XcodeGen のプロジェクト定義
- `Melete/MeleteApp.swift`: 起動時のSwiftData構成とUIテスト用ストアの隔離
- `Melete/Models.swift`: SwiftDataモデル、スキーマ、運動記録削除
- `Melete/MainView.swift`: 履歴・種目画面と保存操作
- `Melete/Forms.swift`, `Melete/MetricInput.swift`: 入力フォームと数値検証
- `MeleteTests/MeleteTests.swift`: 単体テスト
- `MeleteUITests/WorkoutFlowUITests.swift`: 隔離ストアでの画面フローのテスト
- `MeleteUITests/WindowProbeSmokeUITests.swift`: 保存操作なしで起動ウィンドウと隔離ストアを確認するスモークテスト
- `docs/design-doc.md`: ユーザー確認待ちの設計案。実装済み仕様とは区別する

## 生成物とコマンド

`Melete.xcodeproj` は `project.yml` から XcodeGen で生成されるため、プロジェクト設定を変える場合は `project.yml` を編集し、生成物の手編集を避けてください。必要時は `xcodegen generate` で再生成します。

このリポジトリで使えるプロジェクト・scheme名に基づくコマンド:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Melete.xcodeproj -scheme Melete build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Melete.xcodeproj -scheme Melete test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Melete.xcodeproj -scheme Melete -only-testing:MeleteUITests/WorkoutFlowUITests test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Melete.xcodeproj -scheme Melete-WindowProbe -only-testing:MeleteUITests/WindowProbeSmokeUITests test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Melete.xcodeproj -scheme Melete-WindowProbe test
```

`Melete-WindowProbe` はUIテスト起動時のウィンドウ確認およびUIテスト専用で、アプリIDは `jp.iorinu.Melete.UITesting` です。通常の `Melete` schemeは従来どおり `jp.iorinu.Melete` を使い、既存データ向けのビルド・テストに使用します。

Xcode のインストール先が異なる環境では、`DEVELOPER_DIR` のパスを適宜読み替えてください。

UIテストでは `CODE_SIGNING_ALLOWED=NO` を付けないでください。

## データとプライバシー

- ローカルの実データを読み書き・削除したり、初期化したりしないでください。保存や移行を扱う変更は、テスト専用の一時ストアを使ってください。
- 専用ストア引数が存在するが不正な場合、アプリは起動エラーになります。UIテスト起動時は引数と「隔離ストア使用中」表示・ストアマーカーを必ず確認し、いずれかが欠けていたら操作を中断してください。通常ストアへのfallbackを許可しないでください。
- 実APIに個人データを送信しないでください。外部接続の検証にはダミーデータを使い、必要な場合もユーザーの明示的な許可なしに実データを送らないでください。
- AIが提案する変更は、内容を画面で確認し、ユーザーが承認してから適用する設計です。未実装の承認フローを実装済みとして仮定しないでください。
- ログ、テストデータ、コミットに個人情報、実記録、認証情報、秘密情報を含めないでください。

## 設計案と現状

`docs/design-doc.md` は設計案（ユーザー確認待ち）です。AI接続、目標、分析、通知、同期、バックアップ等の記述は、コードで実装を確認できない限り未実装または未確定として扱ってください。設計案の候補や検討結果を確定仕様として記述せず、変更時は現行コードと設計案のどちらに基づくかを明確にしてください。
