# 学習済み U-Net を ONNX(Web版)へ書き出す
# 使い方: python3 export.py <train スクリプト> <重み.pt> <base幅> <出力.onnx>
import sys, torch, torch.nn as nn, torch.nn.functional as F
src, weights, base, out = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
code = open(src).read(); code = code[code.index('def cbr'):code.index('m=UNet(')]
exec(code)
m = UNet(base) if 'def __init__(s,b=16)' in code else UNet()
m.load_state_dict(torch.load(weights, map_location='cpu')); m.eval()
class Wrap(nn.Module):
    def __init__(s, m): super().__init__(); s.m = m
    def forward(s, x): return torch.sigmoid(s.m(x))
torch.onnx.export(Wrap(m), torch.rand(1, 3, 256, 256), out, input_names=['image'], output_names=['prob'],
                  dynamic_axes={'image': {2: 'h', 3: 'w'}, 'prob': {2: 'h', 3: 'w'}}, opset_version=17, dynamo=False)
print('saved', out)
