"""Narrow no-adoption evidence; not a license or derivation scanner."""
import re
import subprocess
import sys

def blobs(root):
    data=subprocess.check_output(["git","-C",root,"ls-tree","-r","-z","HEAD"])
    rows=[]
    for rec in data.split(b"\0"):
        if not rec:
            continue
        meta,path=rec.split(b"\t",1)
        mode,kind,sha=meta.split()
        if kind==b"blob":
            rows.append((path.decode(),sha))
    return rows

up=blobs(sys.argv[1])
own=[(p,h) for p,h in blobs(".") if p=="Package.swift" or p.startswith(("Sources/","Apps/","Adapters/"))]
hashes={h for _,h in up}
identical=[p for p,h in own if h in hashes]
pattern=re.compile(rb"muse-gadget-sdk|gadgets\.muse\.ai|MUSE_SDK_TOKEN|musegadgets",re.I)
markers=[]
for p,_ in own:
    with open(p,"rb") as f:
        if pattern.search(f.read()):
            markers.append(p)
print("tracked production blobs",len(own),"pinned upstream blobs",len(up))
print("exact matching blobs",len(identical),"known Muse markers",len(markers))
if identical or markers:
    raise RuntimeError("no-adoption boundary needs review: "+repr(identical+markers))
print("PASS: narrow production no-adoption checks; not proof of no derivation")
