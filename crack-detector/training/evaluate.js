// 古典手法の評価: 2px許容の画素 P/R/F1
require(require('path').join(__dirname,'..','detector.js'));
const fs=require('fs'), dir=process.argv[2];
function dil(m,w,h,r){const o=new Uint8Array(m.length);for(let y=0;y<h;y++)for(let x=0;x<w;x++){if(!m[y*w+x])continue;for(let dy=-r;dy<=r;dy++)for(let dx=-r;dx<=r;dx++){const yy=y+dy,xx=x+dx;if(yy>=0&&yy<h&&xx>=0&&xx<w)o[yy*w+xx]=1;}}return o;}
const files=fs.readdirSync(dir).filter(f=>f.endsWith('.bin'));
const data=files.map(f=>{const b=fs.readFileSync(dir+'/'+f);const w=b.readInt32LE(0),h=b.readInt32LE(4);const px=new Uint8ClampedArray(b.buffer,b.byteOffset+8,w*h*4);const gt=new Uint8Array(b.buffer,b.byteOffset+8+w*h*4,w*h);const pf=dir+'/'+f.replace('.bin','.prob');const prob=process.env.AI&&fs.existsSync(pf)?new Float32Array(fs.readFileSync(pf).buffer.slice(0)):null;return {w,h,px,gt,prob,gtd:dil(gt,w,h,2)};});
for(const sens of (process.argv[3]||'50').split(',').map(Number)){
 let tp=0,fp=0,tpr=0,fn=0;
 for(const d of data){const r=CrackDetector.detect({data:d.px,width:d.w,height:d.h},{sensitivity:sens},d.prob);
  const pred=new Uint8Array(d.w*d.h);for(let i=0;i<pred.length;i++)pred[i]=r.labels[i]?1:0;const pd=dil(pred,d.w,d.h,2);
  for(let i=0;i<pred.length;i++){if(pred[i]){d.gtd[i]?tp++:fp++;} if(d.gt[i]){pd[i]?tpr++:fn++;}}}
 const P=tp/(tp+fp||1),R=tpr/(tpr+fn),F=2*P*R/(P+R||1);
 console.log(`sens=${sens} P=${P.toFixed(3)} R=${R.toFixed(3)} F1=${F.toFixed(3)}`);
}
