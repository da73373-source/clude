import os,sys,numpy as np
from PIL import Image
D=sys.argv[1]; out=sys.argv[2]
for f in sorted(os.listdir(D+'/test_img')):
    im=np.array(Image.open(D+'/test_img/'+f).convert('RGBA'))
    b=os.path.splitext(f)[0]
    labf=b+'.png'
    lab=(np.array(Image.open(D+'/test_lab/'+labf).convert('L'))>127).astype(np.uint8)
    h,w=lab.shape
    open(f'{out}/{b}.bin','wb').write(np.array([w,h],dtype=np.int32).tobytes()+im.tobytes()+lab.tobytes())
