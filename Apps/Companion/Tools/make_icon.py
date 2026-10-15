"""Generates App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png (needs Pillow).
Usage: python3 Tools/make_icon.py App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"""
import sys
from PIL import Image, ImageDraw
N=1024; SS=4; W=N*SS
img=Image.new("RGB",(W,W),(16,26,38))
d=ImageDraw.Draw(img)
acc=(79,179,255)
lw=int(W*0.045)
cy=W*0.56; r=W*0.15
lx=W*0.33; rx=W*0.67
for cx in (lx,rx):
    d.ellipse([cx-r,cy-r,cx+r,cy+r], outline=acc, width=lw)
d.arc([W*0.5-W*0.07, cy-W*0.07, W*0.5+W*0.07, cy+W*0.05], start=200, end=340, fill=acc, width=lw)
d.line([lx-r, cy-W*0.03, W*0.10, cy-W*0.03], fill=acc, width=lw)
d.line([rx+r, cy-W*0.03, W*0.90, cy-W*0.03], fill=acc, width=lw)
for i,rad in enumerate((0.07,0.12,0.17)):
    R=W*rad; c=(W*0.5, W*0.36)
    col=[acc,(60,140,205),(45,105,155)][i]
    d.arc([c[0]-R,c[1]-R,c[0]+R,c[1]+R], start=225, end=315, fill=col, width=int(W*0.03))
img.resize((N,N), Image.LANCZOS).save(sys.argv[1])
print("ok")
