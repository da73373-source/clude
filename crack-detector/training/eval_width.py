import json, sys, os, numpy as np
from PIL import Image
from skimage.morphology import skeletonize
U=sys.argv[1]
for name in sys.argv[2:]:
    r=json.load(open(name)); g=[]; reg=[]; dk=[]
    for b,v in r.items():
        gt=np.asarray(Image.open(f'{U}/deepcrack/test/lab/{b}.png'))>127; sk=skeletonize(gt).sum()
        if sk<20: continue
        g.append(gt.sum()/sk); reg.append(v['region']); dk.append(v['dark'])
    g=np.array(g); reg=np.array(reg); dk=np.array(dk)
    f=lambda p: f'ratio median {np.median(p/g):.2f} | MAE {np.mean(np.abs(p-g)):.2f}px | within±30% {np.mean(np.abs(p/g-1)<=.3)*100:.0f}%'
    print(f'{name}: n={len(g)} GT mean width median {np.median(g):.2f}px')
    print('   region  :', f(reg)); print('   darkness:', f(dk))
