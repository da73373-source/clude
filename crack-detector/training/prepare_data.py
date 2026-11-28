# 3つのデータセットを data/unified/<name>/<split>/{img,lab}/*.png に統一(lab は 0/255)
import os, sys, random, numpy as np
from PIL import Image
R=sys.argv[1]; O=R+'/unified'
def put(name,split,stem,im,lab):
    for k in ('img','lab'): os.makedirs(f'{O}/{name}/{split}/{k}',exist_ok=True)
    im.convert('RGB').save(f'{O}/{name}/{split}/img/{stem}.png')
    Image.fromarray(((np.asarray(lab)>0)*255).astype(np.uint8)).save(f'{O}/{name}/{split}/lab/{stem}.png')
# DeepCrack(既存の分割)
D=R+'/deepcrack'
for sp in ('train','test'):
    for f in sorted(os.listdir(f'{D}/{sp}_img')):
        b=os.path.splitext(f)[0]
        put('deepcrack',sp,b,Image.open(f'{D}/{sp}_img/{f}'),np.asarray(Image.open(f'{D}/{sp}_lab/{b}.png').convert('L'))>127)
# aidonchuk(80/20 に分割、空マスクは除外)
A=R+'/cracks_segmentation_dataset/ds'
fs=sorted(os.listdir(A+'/img')); random.Random(42).shuffle(fs); n=0
for i,f in enumerate(fs):
    b=os.path.splitext(f)[0]
    mp=[p for p in (f'{A}/masks_machine/{f}.png',f'{A}/masks_machine/{b}.png',f'{A}/masks_machine/{f}') if os.path.exists(p)][0]
    m=np.asarray(Image.open(mp))
    if m.ndim==3: m=m[...,0]
    if (m>0).sum()==0: continue
    put('aid','test' if i%5==0 else 'train',b,Image.open(f'{A}/img/{f}'),m>0); n+=1
print('aid',n)
# DIMEC(train+val を学習、test をテスト)
M=R+'/dimec'
for v in ('v1','v2'):
    for sp,dst in (('train','train'),('val','train'),('test','test')):
        d=f'{M}/crack_images_{v}_s1'
        for f in sorted(os.listdir(f'{d}/{sp}')):
            b=os.path.splitext(f)[0]
            put('dimec',dst,b,Image.open(f'{d}/{sp}/{f}'),np.asarray(Image.open(f'{d}/{sp}_labels/{b}.png').convert('L'))>127)
for name in os.listdir(O):
    for sp in os.listdir(f'{O}/{name}'): print(name,sp,len(os.listdir(f'{O}/{name}/{sp}/img')))
