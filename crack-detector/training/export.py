import sys, torch, re
src=open(sys.argv[1]+'/train.py').read()
# モデル定義だけ取り出す
code=src[src.index('def cbr'):src.index('m=UNet()')]
import torch.nn as nn, torch.nn.functional as F
exec(code)
m=UNet(); m.load_state_dict(torch.load(sys.argv[1]+'/best.pt')); m.eval()
class Wrap(nn.Module):
    def __init__(s,m): super().__init__(); s.m=m
    def forward(s,x): return torch.sigmoid(s.m(x))
torch.onnx.export(Wrap(m), torch.rand(1,3,256,256), sys.argv[2], input_names=['image'], output_names=['prob'],
    dynamic_axes={'image':{2:'h',3:'w'},'prob':{2:'h',3:'w'}}, opset_version=17, dynamo=False)
import onnx; mo=onnx.load(sys.argv[2])
if len(mo.graph.initializer)==0 or any(i.data_location==1 for i in mo.graph.initializer):
    onnx.save(mo, sys.argv[2], save_as_external_data=False)
print('ok')
