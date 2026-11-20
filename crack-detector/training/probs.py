# ONNXモデルでテスト画像の確率マップを作り raw/*.prob に保存
import os,sys,numpy as np,onnxruntime as ort
from PIL import Image
D,model,out=sys.argv[1:4]
s=ort.InferenceSession(model)
for f in sorted(os.listdir(D+'/test_img')):
    a=np.asarray(Image.open(D+'/test_img/'+f).convert('RGB'),np.float32).transpose(2,0,1)/255.
    _,h,w=a.shape; H,W=(h+15)//16*16,(w+15)//16*16
    x=np.pad(a,((0,0),(0,H-h),(0,W-w)),mode='edge')[None]
    p=s.run(None,{'image':x})[0][0,0,:h,:w].astype(np.float32)
    p.tofile(f'{out}/{os.path.splitext(f)[0]}.prob')
