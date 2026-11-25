"""Bounded deterministic parser corpus. No devices, network, or credentials."""
import random
import resource
import subprocess
import sys
from collections import Counter
from musegadget.noise import framing

rng=random.Random(641)
seed=framing.encode_noise_frames(b"AWL host synthetic",chunk_id=7)[0]
assert len(seed)<=128
cases=[b"",seed]+[seed[:i] for i in range(len(seed))]
for i in range(len(seed)):
    for bit in range(8):
        m=bytearray(seed);m[i]^=1<<bit;cases.append(bytes(m))
for _ in range(128):
    cases.append(bytes(rng.randrange(256) for _ in range(rng.randrange(65))))
assert len(cases)<2048 and all(len(c)<=128 for c in cases)
p=subprocess.run([sys.argv[1],"scan"],input="".join(x.hex()+"\n" for x in cases),
                 text=True,stdout=subprocess.PIPE,check=True,timeout=30)
cpp=Counter(p.stdout.splitlines())
assert sum(cpp.values())==len(cases)
assert set(cpp)<={"complete","partial","rejected","resource"}
py=Counter()
for case in cases:
    try:
        outcome=framing.NoiseFrameDecoder().decode(case)
        py["partial" if outcome is None else "complete"]+=1
    except (ValueError,RuntimeError):
        py["rejected"]+=1
assert sum(py.values())==len(cases)
print("seeded mutation/truncation/random corpus cases=",len(cases)," max_input_bytes=",max(map(len,cases)),sep="")
print("C++ outcomes",dict(sorted(cpp.items())))
print("Python outcomes",dict(sorted(py.items())))
print("host maxrss KiB: Python=",resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
      " child=",resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss,sep="")
print("PASS: completed bounded corpus under instrumented C++ parser; policies may differ")
