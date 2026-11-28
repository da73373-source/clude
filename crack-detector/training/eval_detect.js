// アプリと同じ detect() で各画像を処理し、検出マスクを書き出す
require(require('path').join(__dirname,'..','detector.js'));
const fs=require('fs'), path=require('path'), dir=process.argv[2], sens=+(process.argv[3]||50);
for (const name of fs.readdirSync(dir)) {
  const d=path.join(dir,name);
  for (const f of fs.readdirSync(d).filter(f=>f.endsWith('.bin'))) {
    const b=fs.readFileSync(path.join(d,f)); const w=b.readInt32LE(0),h=b.readInt32LE(4);
    const px=new Uint8ClampedArray(b.buffer,b.byteOffset+8,w*h*4);
    const prob=new Float32Array(fs.readFileSync(path.join(d,f.replace('.bin','.prob'))).buffer.slice(0));
    const r=CrackDetector.detect({data:px,width:w,height:h},{sensitivity:sens},prob);
    const m=new Uint8Array(w*h); for(let i=0;i<m.length;i++) m[i]=r.labels[i]?1:0;
    fs.writeFileSync(path.join(d,f.replace('.bin','.mask')),m);
  }
}
