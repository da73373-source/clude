# 検出マスクと正解を比較: 画素F1(2px許容)と中心線F1(3px許容)
import os, sys, numpy as np, torch, torch.nn.functional as F
from PIL import Image
from skimage.morphology import skeletonize
U, dir_ = sys.argv[1:3]
def dil(m,r): return (F.max_pool2d(torch.from_numpy(m[None,None].astype(np.float32)),2*r+1,1,r)[0,0]>0).numpy()
f1=lambda a,b,c,d:(lambda P,R:(P,R,2*P*R/(P+R+1e-9)))(a/max(b,1),c/max(d,1))
for name in sorted(os.listdir(dir_)):
    c=np.zeros(8)
    for f in sorted(os.listdir(f'{U}/{name}/test/lab')):
        gt=np.asarray(Image.open(f'{U}/{name}/test/lab/{f}'))>127
        pr=np.fromfile(f'{dir_}/{name}/{os.path.splitext(f)[0]}.mask',np.uint8).reshape(gt.shape)>0
        sp=skeletonize(pr); sg=skeletonize(gt)
        c+=[(pr&dil(gt,2)).sum(),pr.sum(),(gt&dil(pr,2)).sum(),gt.sum(),(sp&dil(sg,3)).sum(),sp.sum(),(sg&dil(sp,3)).sum(),sg.sum()]
    a=f1(*c[:4]); b=f1(*c[4:])
    print(f'{name:10s} pixel P={a[0]:.3f} R={a[1]:.3f} F1={a[2]:.3f} | centerline P={b[0]:.3f} R={b[1]:.3f} F1={b[2]:.3f}')
