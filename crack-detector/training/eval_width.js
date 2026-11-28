// 各画像の平均幅(ひびの長さで加重): 領域ベース と 暗さベース
require(require('path').join(__dirname,'..','detector.js'));
const fs=require('fs'), d=process.argv[2]+'/deepcrack', out={};
for (const f of fs.readdirSync(d).filter(f=>f.endsWith('.bin'))) {
  const b=fs.readFileSync(d+'/'+f); const w=b.readInt32LE(0),h=b.readInt32LE(4);
  const prob=new Float32Array(fs.readFileSync(d+'/'+f.replace('.bin','.prob')).buffer.slice(0));
  const r=CrackDetector.detect({data:new Uint8ClampedArray(b.buffer,b.byteOffset+8,w*h*4),width:w,height:h},{darkWidthScale:+(process.env.K||1.6)},prob);
  let L=0, reg=0, dk=0, src=0;
  for (const c of r.cracks){ L+=c.lengthPx; reg+=c.area; dk+=c.meanWidthPx*c.lengthPx; src+=c.widthSource==='darkness'; }
  if (L>0) out[f.replace('.bin','')]={region:reg/L, dark:dk/L, n:r.cracks.length, darkSrc:src};
}
fs.writeFileSync(process.argv[3], JSON.stringify(out));
