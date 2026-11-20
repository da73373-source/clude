import os, sys, time, random, numpy as np, torch, torch.nn as nn, torch.nn.functional as F
from PIL import Image, ImageFilter, ImageEnhance
torch.set_num_threads(4); random.seed(0); torch.manual_seed(0)
D=sys.argv[1]; OUT=sys.argv[2]; EPOCHS=int(sys.argv[3]) if len(sys.argv)>3 else 80
def load(split):
    xs=[]
    for f in sorted(os.listdir(f'{D}/{split}_img')):
        b=os.path.splitext(f)[0]; lf=b+'.png'
        xs.append((Image.open(f'{D}/{split}_img/{f}').convert('RGB'), Image.open(f'{D}/{split}_lab/{lf}').convert('L')))
    return xs
alltr=load('train'); random.shuffle(alltr); val=alltr[:30]; train=alltr[30:]; test=load('test')
C=256
def aug(im,lb):
    s=random.uniform(0.6,1.8); w,h=im.size; nw,nh=max(C,int(w*s)),max(C,int(h*s))
    im=im.resize((nw,nh),Image.BILINEAR); lb=lb.resize((nw,nh),Image.BILINEAR)
    x=random.randint(0,nw-C); y=random.randint(0,nh-C)
    im=im.crop((x,y,x+C,y+C)); lb=lb.crop((x,y,x+C,y+C))
    if random.random()<.5: im=im.transpose(Image.FLIP_LEFT_RIGHT); lb=lb.transpose(Image.FLIP_LEFT_RIGHT)
    k=random.randint(0,3)
    if k: im=im.rotate(90*k); lb=lb.rotate(90*k)
    im=ImageEnhance.Brightness(im).enhance(random.uniform(.6,1.4))
    im=ImageEnhance.Contrast(im).enhance(random.uniform(.6,1.4))
    im=ImageEnhance.Color(im).enhance(random.uniform(0,1.5))
    if random.random()<.3: im=im.filter(ImageFilter.GaussianBlur(random.uniform(.3,1.2)))
    a=np.asarray(im,np.float32)/255.
    if random.random()<.5: a=a+np.random.normal(0,random.uniform(.005,.04),a.shape)
    # 照明ムラ
    if random.random()<.5:
        g=np.linspace(random.uniform(.7,1.1),random.uniform(.9,1.3),C)[None,:,None]
        a=a*(g if random.random()<.5 else g.transpose(1,0,2))
    return np.clip(a,0,1).transpose(2,0,1), (np.asarray(lb,np.float32)/255.>.5).astype(np.float32)[None]
def cbr(i,o): return nn.Sequential(nn.Conv2d(i,o,3,padding=1,bias=False),nn.BatchNorm2d(o),nn.ReLU(inplace=True),nn.Conv2d(o,o,3,padding=1,bias=False),nn.BatchNorm2d(o),nn.ReLU(inplace=True))
class UNet(nn.Module):
    def __init__(s,c=(16,32,64,128)):
        super().__init__()
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
m=UNet(); print('params',sum(p.numel() for p in m.parameters()),flush=True)
opt=torch.optim.AdamW(m.parameters(),2e-3,weight_decay=1e-4)
steps_per=40; B=8
sched=torch.optim.lr_scheduler.OneCycleLR(opt,3e-3,total_steps=EPOCHS*steps_per)
def loss_fn(lo,y):
    p=torch.sigmoid(lo); dice=1-(2*(p*y).sum()+1)/(p.sum()+y.sum()+1)
    return F.binary_cross_entropy_with_logits(lo,y,pos_weight=torch.tensor(3.))+dice
def evaluate(data=None):
    data=data or val
    m.eval(); res={t:[0,0,0] for t in (.3,.4,.5,.6)}
    with torch.no_grad():
        for im,lb in data:
            w,h=im.size; W,H=(w+15)//16*16,(h+15)//16*16
            a=np.zeros((3,H,W),np.float32); a[:,:h,:w]=np.asarray(im,np.float32).transpose(2,0,1)/255.
            p=torch.sigmoid(m(torch.from_numpy(a)[None]))[0,0,:h,:w].numpy()
            gt=np.asarray(lb)>127; gtd=torch.from_numpy(gt[None,None].astype(np.float32)); gtd=(F.max_pool2d(gtd,5,1,2)[0,0]>0).numpy()
            for t in res:
                pr=p>t; prd=(F.max_pool2d(torch.from_numpy(pr[None,None].astype(np.float32)),5,1,2)[0,0]>0).numpy()
                res[t][0]+=(pr&gtd).sum(); res[t][1]+=pr.sum(); res[t][2]+=0
                res[t].append(((gt&prd).sum(),gt.sum()))
    out={}
    for t,v in res.items():
        P=v[0]/max(v[1],1); R=sum(a for a,b in v[3:])/sum(b for a,b in v[3:]); out[t]=(P,R,2*P*R/(P+R+1e-9))
    m.train(); return out
best=0; t0=time.time()
for ep in range(EPOCHS):
    tl=0
    for it in range(steps_per):
        bx,by=zip(*[aug(*random.choice(train)) for _ in range(B)])
        x=torch.from_numpy(np.stack(bx)).float(); y=torch.from_numpy(np.stack(by))
        l=loss_fn(m(x),y); opt.zero_grad(); l.backward(); opt.step(); sched.step(); tl+=l.item()
    msg=f'ep {ep} loss {tl/steps_per:.3f} t {time.time()-t0:.0f}s'
    if ep%5==4 or ep==EPOCHS-1:
        r=evaluate(); f=max(v[2] for v in r.values())
        msg+=' '+' '.join(f'{t}:P{v[0]:.3f}/R{v[1]:.3f}/F{v[2]:.3f}' for t,v in r.items())
        if f>best: best=f; torch.save(m.state_dict(),OUT+'/best.pt')
    print(msg,flush=True)

m.load_state_dict(torch.load(OUT+'/best.pt')); r=evaluate(test)
print('TEST',' '.join(f'{t}:P{v[0]:.3f}/R{v[1]:.3f}/F{v[2]:.3f}' for t,v in r.items()),flush=True)
