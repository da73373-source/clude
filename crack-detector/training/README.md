# AIモデルの学習・評価

`../model/crack-unet.onnx` は以下の手順で作成しています(CPUで約25分)。

```bash
pip install torch onnx onnxruntime pillow numpy
git clone --depth 1 https://github.com/yhlleo/DeepCrack.git
mkdir deepcrack && (cd deepcrack && unzip -q ../DeepCrack/dataset/DeepCrack.zip)

python3 train.py deepcrack . 60                   # best.pt を出力(学習300枚のうち30枚を検証用に使用)
python3 export.py . ../model/crack-unet.onnx      # ONNX へ書き出し

# 評価(テスト237枚、アプリと同じ後処理込み・2px許容の画素 F1)
mkdir raw && python3 dump.py deepcrack raw
node evaluate.js raw 50                           # 画像処理方式
python3 probs.py deepcrack ../model/crack-unet.onnx raw
AI=1 node evaluate.js raw 50                      # AI方式
```

- モデル: 小型 U-Net(約48万パラメータ, 1.9MB)。入力 RGB(0〜1)、出力はひびの確率マップ
- データ拡張: 拡大縮小(0.6〜1.8倍)、回転・反転、明るさ・コントラスト・彩度、ぼかし、ノイズ、照明ムラ
- 学習データ: [DeepCrack](https://github.com/yhlleo/DeepCrack)(Liu et al., Neurocomputing 2019)
