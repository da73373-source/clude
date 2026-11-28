# 複数データセットでの U-Net 学習(DeepCrack + aid + DIMEC)
import os, sys, time, random, argparse, numpy as np, torch, torch.nn as nn, torch.nn.functional as F
from PIL import Image, ImageFilter, ImageEnhance, ImageDraw
from skimage.morphology import skeletonize
ap=argparse.ArgumentParser()
ap.add_argument('data'); ap.add_argument('out'); ap.add_argument('--epochs',type=int,default=80)
ap.add_argument('--base',type=int,default=16); ap.add_argument('--steps',type=int,default=40); ap.add_argument('--bench',action='store_true')
args=ap.parse_args()
torch.set_num_threads(4); random.seed(0); np.random.seed(0); torch.manual_seed(0)
U=args.data
def load(name,split):
    d=f'{U}/{name}/{split}'
    return [(Image.open(f'{d}/img/{f}').convert('RGB'),Image.open(f'{d}/lab/{f}').convert('L')) for f in sorted(os.listdir(d+'/img'))]
sets={}; val={}
for name in ('deepcrack','aid','dimec'):
    xs=load(name,'train'); random.Random(1).shuffle(xs); k=max(10,len(xs)//10)
    if name=='dimec': k=200
    val[name]=xs[:k]; sets[name]=xs[k:]
print({k:len(v) for k,v in sets.items()},{k:len(v) for k,v in val.items()},flush=True)

def photometric(im):
    im=ImageEnhance.Brightness(im).enhance(random.uniform(.6,1.4))
    im=ImageEnhance.Contrast(im).enhance(random.uniform(.6,1.4))
    im=ImageEnhance.Color(im).enhance(random.uniform(0,1.5))
    if random.random()<.3: im=im.filter(ImageFilter.GaussianBlur(random.uniform(.3,1.2)))
    return im
def stains(im):
    # 誤検出対策: ぼやけた暗いシミ(正解はひびなし)を重ねる
    if random.random()<.3:
        w,h=im.size; ov=Image.new('L',im.size,0); d=ImageDraw.Draw(ov)
        for _ in range(random.randint(1,3)):
            cx,cy=random.uniform(0,w),random.uniform(0,h); rx,ry=random.uniform(.05,.25)*w,random.uniform(.05,.25)*h
            d.ellipse((cx-rx,cy-ry,cx+rx,cy+ry),fill=random.randint(40,110))
        ov=ov.filter(ImageFilter.GaussianBlur(random.uniform(3,12)))
        im=Image.composite(Image.new('RGB',im.size,(25,22,20)),im,ov)
    return im
def aug(im,lb,C,smin,smax):
    s=random.uniform(smin,smax); w,h=im.size; nw,nh=max(C,int(w*s)),max(C,int(h*s))
    im=im.resize((nw,nh),Image.BILINEAR); lb=lb.resize((nw,nh),Image.BILINEAR)
    x=random.randint(0,nw-C); y=random.randint(0,nh-C)
    im=im.crop((x,y,x+C,y+C)); lb=lb.crop((x,y,x+C,y+C))
    if random.random()<.5: im=im.transpose(Image.FLIP_LEFT_RIGHT); lb=lb.transpose(Image.FLIP_LEFT_RIGHT)
    k=random.randint(0,3)
    if k: im=im.rotate(90*k); lb=lb.rotate(90*k)
    im=stains(photometric(im))
    a=np.asarray(im,np.float32)/255.
    if random.random()<.5: a=a+np.random.normal(0,random.uniform(.005,.04),a.shape)
    if random.random()<.5:
        g=np.linspace(random.uniform(.7,1.1),random.uniform(.9,1.3),C)[None,:,None]
        a=a*(g if random.random()<.5 else g.transpose(1,0,2))
    return np.clip(a,0,1).transpose(2,0,1),(np.asarray(lb,np.float32)/255.>.5).astype(np.float32)[None]
def batch():
    if random.random()<.25:   # DIMEC(96px の小画像)
        return [aug(*random.choice(sets['dimec']),96,1.0,1.6) for _ in range(24)]
    out=[]
    for _ in range(8):
        name='deepcrack' if random.random()<.55 else 'aid'
        out.append(aug(*random.choice(sets[name]),256,0.6,1.8))
    return out

def cbr(i,o): return nn.Sequential(nn.Conv2d(i,o,3,padding=1,bias=False),nn.BatchNorm2d(o),nn.ReLU(inplace=True),nn.Conv2d(o,o,3,padding=1,bias=False),nn.BatchNorm2d(o),nn.ReLU(inplace=True))
class UNet(nn.Module):
    def __init__(s,b=16):
        super().__init__(); c=(b,b*2,b*4,b*8)
        s.e1=cbr(3,c[0]); s.e2=cbr(c[0],c[1]); s.e3=cbr(c[1],c[2]); s.b=cbr(c[2],c[3])
        s.u3=nn.ConvTranspose2d(c[3],c[2],2,2); s.d3=cbr(c[2]*2,c[2])
        s.u2=nn.ConvTranspose2d(c[2],c[1],2,2); s.d2=cbr(c[1]*2,c[1])
        s.u1=nn.ConvTranspose2d(c[1],c[0],2,2); s.d1=cbr(c[0]*2,c[0])
        s.o=nn.Conv2d(c[0],1,1)
    def forward(s,x):
        x=(x-0.5)/0.25
        e1=s.e1(x); e2=s.e2(F.max_pool2d(e1,2)); e3=s.e3(F.max_pool2d(e2,2)); b=s.b(F.max_pool2d(e3,2))
        d3=s.d3(torch.cat([s.u3(b),e3],1)); d2=s.d2(torch.cat([s.u2(d3),e2],1)); d1=s.d1(torch.cat([s.u1(d2),e1],1))
        return s.o(d1)
m=UNet(args.base); print('params',sum(p.numel() for p in m.parameters()),flush=True)
opt=torch.optim.AdamW(m.parameters(),2e-3,weight_decay=1e-4)
sched=torch.optim.lr_scheduler.OneCycleLR(opt,3e-3,total_steps=args.epochs*args.steps)
def loss_fn(lo,y):
    p=torch.sigmoid(lo); dice=1-(2*(p*y).sum()+1)/(p.sum()+y.sum()+1)
    return F.binary_cross_entropy_with_logits(lo,y,pos_weight=torch.tensor(3.))+dice

def dil(m,r): return (F.max_pool2d(torch.from_numpy(m[None,None].astype(np.float32)),2*r+1,1,r)[0,0]>0).numpy()
def predict(im):
    a=np.asarray(im,np.float32).transpose(2,0,1)/255.; _,h,w=a.shape; H,W=(h+15)//16*16,(w+15)//16*16
    x=torch.from_numpy(np.pad(a,((0,0),(0,H-h),(0,W-w)),mode='edge'))[None]
    with torch.no_grad(): return torch.sigmoid(m(x))[0,0,:h,:w].numpy()
def evaluate(data):
    """画素F1(2px許容)と中心線F1(骨格どうし, 3px許容)"""
    m.eval(); res={}
    for name,xs in data.items():
        c=np.zeros(8)
        for im,lb in xs:
            pr=predict(im)>0.5; gt=np.asarray(lb)>127
            c[:4]+=[(pr&dil(gt,2)).sum(),pr.sum(),(gt&dil(pr,2)).sum(),gt.sum()]
            sp=skeletonize(pr); sg=skeletonize(gt)
            c[4:]+=[(sp&dil(sg,3)).sum(),sp.sum(),(sg&dil(sp,3)).sum(),sg.sum()]
        f=lambda a,b,c_,d: (lambda P,R:(P,R,2*P*R/(P+R+1e-9)))(a/max(b,1),c_/max(d,1))
        res[name]=(f(*c[:4]),f(*c[4:]))
    m.train(); return res
def fmt(r): return ' '.join(f'{k}:px{v[0][2]:.3f}/cl{v[1][2]:.3f}' for k,v in r.items())

if args.bench:
    t=time.time()
    for _ in range(5):
        bx,by=zip(*batch()); l=loss_fn(m(torch.from_numpy(np.stack(bx)).float()),torch.from_numpy(np.stack(by))); opt.zero_grad(); l.backward(); opt.step()
    print('sec/step',(time.time()-t)/5); sys.exit()

best=-1; t0=time.time()
for ep in range(args.epochs):
    tl=0
    for it in range(args.steps):
        bx,by=zip(*batch())
        l=loss_fn(m(torch.from_numpy(np.stack(bx)).float()),torch.from_numpy(np.stack(by)))
        opt.zero_grad(); l.backward(); opt.step(); sched.step(); tl+=l.item()
    msg=f'ep {ep} loss {tl/args.steps:.3f} t {time.time()-t0:.0f}s'
    if ep%5==4 or ep==args.epochs-1:
        r=evaluate(val); score=np.mean([v[1][2] for v in r.values()])
        msg+=f' val {fmt(r)} mean_cl {score:.3f}'
        if score>best: best=score; torch.save(m.state_dict(),f'{args.out}/best2.pt')
    print(msg,flush=True)
m.load_state_dict(torch.load(f'{args.out}/best2.pt'))
test={n:load(n,'test') for n in ('deepcrack','aid','dimec')}
print('TEST',fmt(evaluate(test)),flush=True)
