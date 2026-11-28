# ONNX モデルで各テストセットの確率マップを作り、アプリの後処理(detector.js)で評価できる形にする
import os, sys, numpy as np, onnxruntime as ort
from PIL import Image
U, model, out = sys.argv[1:4]; tta='--tta' in sys.argv
ss = [ort.InferenceSession(x) for x in model.split(',')]
def run(a):
    _,h,w=a.shape; H,W=(h+15)//16*16,(w+15)//16*16
    x=np.pad(a,((0,0),(0,H-h),(0,W-w)),mode='edge')[None]
    return sum(s.run(None,{'image':x})[0][0,0,:h,:w] for s in ss)/len(ss)
for name in sorted(os.listdir(U)):
    d=f'{U}/{name}/test'; o=f'{out}/{name}'; os.makedirs(o,exist_ok=True)
    for f in sorted(os.listdir(d+'/img')):
        im=Image.open(f'{d}/img/{f}').convert('RGB'); a=np.asarray(im,np.float32).transpose(2,0,1)/255.
        p=run(a)
        if tta: p=(p+run(a[:,:,::-1].copy())[:,::-1]+run(a[:,::-1,:].copy())[::-1,:])/3
        b=os.path.splitext(f)[0]; h,w=p.shape
        rgba=np.asarray(im.convert('RGBA'))
        open(f'{o}/{b}.bin','wb').write(np.array([w,h],np.int32).tobytes()+rgba.tobytes())
        p.astype(np.float32).tofile(f'{o}/{b}.prob')
