# 学習済み U-Net を Core ML(mlpackage)へ変換
# 入力: 512x512 RGB 画像(0-255、モデル内で /255)、出力: ひび確率 [1,1,512,512]
import sys, importlib.util, torch, torch.nn as nn, coremltools as ct
src, weights, base, out = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
code = open(src).read(); code = code[code.index('def cbr'):code.index('m=UNet(')]
import torch.nn.functional as F
exec(code)
m = UNet(base) if 'def __init__(s,b=16)' in code else UNet()
m.load_state_dict(torch.load(weights, map_location='cpu')); m.eval()
class Wrap(nn.Module):
    def __init__(s, m): super().__init__(); s.m = m
    def forward(s, x): return torch.sigmoid(s.m(x))
ex = torch.rand(1, 3, 512, 512)
tr = torch.jit.trace(Wrap(m), ex)
ml = ct.convert(tr, inputs=[ct.ImageType(name='image', shape=ex.shape, scale=1/255., color_layout=ct.colorlayout.RGB)],
                outputs=[ct.TensorType(name='prob')], minimum_deployment_target=ct.target.iOS16,
                compute_precision=ct.precision.FLOAT16, convert_to='mlprogram')
ml.short_description = 'Crack segmentation U-Net (probability map)'
ml.save(out); print('saved', out)
