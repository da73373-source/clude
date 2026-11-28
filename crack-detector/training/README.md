# AIモデルの学習・評価

`../model/crack-unet.onnx`(Web版)と `../../ios/CrackDetector/Resources/CrackUNet.mlpackage`(iOS版)は、
以下の手順で作成しています(CPU 4コアで約1時間)。

## データ

| データセット | 内容 | 学習 / テスト | ライセンス |
|---|---|---|---|
| [DeepCrack](https://github.com/yhlleo/DeepCrack) | 路面・壁面など | 300 / 237 | 研究用(論文の引用が必要) |
| [cracks_segmentation_dataset](https://github.com/aidonchuk/cracks_segmentation_dataset)(aid) | 路面(CFD・AigleRN など) | 257 / 62(8:2 に分割) | CC BY 4.0 |
| [DIMEC Crack Database](https://github.com/jedota/Crack_Database) | コンクリート橋(96px) | 5,127 / 571 | 研究用 |

```bash
pip install torch onnx onnxruntime coremltools scikit-image pillow numpy
mkdir data && cd data
git clone --depth 1 https://github.com/yhlleo/DeepCrack.git
mkdir deepcrack && (cd deepcrack && unzip -q ../DeepCrack/dataset/DeepCrack.zip)
git clone --depth 1 https://github.com/aidonchuk/cracks_segmentation_dataset.git
git clone --depth 1 https://github.com/jedota/Crack_Database.git
mkdir dimec && (cd dimec && for z in ../Crack_Database/*.zip; do unzip -q -o "$z"; done)
cd ..
python3 prepare_data.py data            # data/unified/<dataset>/<train|test>/{img,lab}
```

## 学習と書き出し

```bash
python3 train.py data/unified . --base 24 --epochs 80     # best2.pt(各データセットの1割を検証用に使用)
python3 export_onnx.py train.py best2.pt 24 ../model/crack-unet.onnx
python3 export_coreml.py train.py best2.pt 24 ../../ios/CrackDetector/Resources/CrackUNet.mlpackage
```

- モデル: U-Net(約108万パラメータ)。入力 RGB(0〜1)、出力はひびの確率マップ
- データ拡張: 拡大縮小、回転・反転、明るさ・コントラスト・彩度、ぼかし、ノイズ、照明ムラ、ぼやけたシミ

## 評価(アプリと同じ後処理込み)

```bash
python3 eval_prepare.py data/unified ../model/crack-unet.onnx out   # 確率マップを作成
node eval_detect.js out 50                                           # detector.js で検出(感度50)
python3 eval_metrics.py data/unified out                             # 画素F1(2px許容)と中心線F1(3px許容)
node eval_width.js out widths.json && python3 eval_width.py data/unified widths.json   # 幅の精度(DeepCrack)
```

- **画素F1**: 検出した画素と正解画素の一致(2px のずれを許容)
- **中心線F1**: 検出と正解の骨格どうしの一致(3px 許容)。正解の塗り方(太さ)の違いに左右されにくい

## 試したが採用しなかったもの

| 手法 | 結果 |
|---|---|
| 左右・上下反転の平均(TTA) | 精度の差がほぼなく、処理が3倍になる |
| 新旧モデルの平均 | DeepCrack は向上するが DIMEC が大きく低下 |
| 合成したタイル・レンガ・サイディングの目地で追加学習 | ひびのない写真の誤検出面積は 20%→14% に減るが、ひびの検出精度が全体に低下 |
| ハフ変換で長い直線(目地)を除外する後処理 | 誤検出は 20%→17% と少ししか減らず、小さく写った本物のひびを消してしまう |
