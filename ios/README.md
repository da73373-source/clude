# ひび割れ検出 iOS アプリ

壁・基礎などの写真から、ひび割れを AI(Core ML)で検出し、長さ・幅の目安と危険度を表示する iPhone / iPad アプリです。
解析はすべて端末内で行い、写真は外部に送信されません。

## 機能

- カメラで撮影 / 写真ライブラリから選択 / サンプル画像
- AI(U-Net, Core ML)でひびを検出し、色付きの枠と番号で表示
- ひびごとの長さ・平均幅・最大幅
- 写真の横幅の実寸(cm)を入力すると mm 表示と危険度判定(ヘアクラック / 要注意 / 要点検)
- 感度・最小の長さ・細長さのしきい値を調整(再推論なしで即時に反映)
- 検出結果画像の共有・保存

## ビルド方法

必要なもの: macOS、Xcode 16 以降、[XcodeGen](https://github.com/yonaskolb/XcodeGen)

```bash
brew install xcodegen
cd ios
xcodegen generate          # CrackDetector.xcodeproj を生成
open CrackDetector.xcodeproj
```

1. Xcode でターゲット **CrackDetector** を選び、「Signing & Capabilities」で自分の Team を選択
   (無料の Apple ID でも実機にインストールできます。7日ごとに再インストールが必要)
2. 必要なら Bundle Identifier を自分用に変更(例: `com.<あなたの名前>.crackdetector`)
3. iPhone を接続して ▶︎ で実行

テスト: `⌘U`、またはコマンドラインで

```bash
xcodebuild test -project CrackDetector.xcodeproj -scheme CrackDetector \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

GitHub Actions(`.github/workflows/ios.yml`)でも、push のたびに macOS 上でビルドとテストを実行しています。

## 構成

| ファイル | 内容 |
|---|---|
| `CrackDetector/Detector/CrackModel.swift` | Core ML 推論(長辺1024pxに縮小、512px タイルに分割) |
| `CrackDetector/Detector/CrackAnalyzer.swift` | 二値化・細線化・距離変換による長さ・幅の計測と判定(Web 版 `detector.js` と同じ処理) |
| `CrackDetector/Detector/OverlayRenderer.swift` | 結果の描画 |
| `CrackDetector/DetectionViewModel.swift` | 状態管理 |
| `CrackDetector/Views/` | 画面(SwiftUI) |
| `CrackDetector/Resources/CrackUNet.mlpackage` | 学習済みモデル(`../crack-detector/training/` で学習し `to_coreml.py` で変換) |
| `CrackDetectorTests/` | 計測処理のテストと、実写真でのモデルの精度テスト |

## 注意

結果は AI による簡易的な目安です。建物の安全性の判断は、専門家による調査を受けてください。
テスト画像(`CrackDetectorTests/Resources/`)は [cracks_segmentation_dataset](https://github.com/aidonchuk/cracks_segmentation_dataset)(CC BY 4.0)から引用しています。
