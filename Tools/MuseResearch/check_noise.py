"""Offline cross-language host fixture; no socket, target device, credentials or key logs."""
import subprocess
import sys
from unittest.mock import patch

from musegadget.noise import framing, NoiseXXResponder

BIN = sys.argv[1]

def check(condition, label):
    if not condition:
        raise RuntimeError(label)

def run(mode, frames):
    data = "".join(x.hex() + "\n" for x in frames)
    p = subprocess.run([BIN, mode], input=data, text=True, stdout=subprocess.PIPE,
                       check=True, timeout=15)
    return p.stdout.splitlines()

def frame(idx=0, total=2, chunk_id=7, payload=b"x"):
    return framing.encode_noise_frame(
        framing.NoiseTransportFrame(chunk_id=chunk_id, chunk_index=idx,
                                    total_chunks=total, payload=payload))

def fails(call, label):
    try:
        call()
    except (ValueError, RuntimeError):
        return
    raise RuntimeError(label)

for size in (1, 4096, framing.MAX_CHUNK_PAYLOAD, framing.MAX_CHUNK_PAYLOAD + 17):
    payload = bytes(i % 251 for i in range(size))
    python_frames = framing.encode_noise_frames(payload, chunk_id=7)
    result = run("decode", python_frames)
    check(result == ["more"] * (len(python_frames)-1) + ["complete:" + payload.hex()],
          "Python-to-C++ ordered reassembly")
    cpp_frames = [bytes.fromhex(line) for line in run("encode", [payload])]
    decoder = framing.NoiseFrameDecoder()
    parts = [decoder.decode(x) for x in cpp_frames]
    check(parts == [None]*(len(cpp_frames)-1)+[payload], "C++-to-Python ordered reassembly")
    print("ordered duplex bytes=" + str(size) + " PASS", flush=True)

first, second = frame(0), frame(1)
check(run("decode", [first, first, second]) == ["more","violation","violation"],
      "C++ duplicate poison")
decoder = framing.NoiseFrameDecoder()
check(decoder.decode(first) is None,"Python first")
fails(lambda: decoder.decode(first),"Python duplicate must fail")
fails(lambda: decoder.decode(second),"Python poison remains")
print("active duplicate and subsequent rejection PASS", flush=True)

check(run("decode",[second,first]) == ["violation","violation"],"C++ order policy")
decoder = framing.NoiseFrameDecoder()
check(decoder.decode(second) is None and decoder.decode(first)==b"xx","Python order policy")
print("out-of-order policy difference PASS", flush=True)

check(run("decode",[b"\x00",first])==["violation","violation"],"C++ malformed poison")
decoder=framing.NoiseFrameDecoder()
fails(lambda:decoder.decode(b"\x00"),"Python malformed")
fails(lambda:decoder.decode(first),"Python malformed poison remains")
print("malformed frame and subsequent rejection PASS", flush=True)

large_first=frame(payload=b"xx")
check(run("decode-small",[large_first,large_first])==["resource","resource"],"local output shortfall")
print("C++ local capacity non-consuming status PASS", flush=True)

# Compare counts without allocating 16 MiB or producing hundreds of frames.
boundary=frame(total=257)
check(run("decode",[boundary])==["more"],"C++ derived ceiling")
fails(lambda:framing.NoiseFrameDecoder().decode(boundary),"Python 256 ceiling")
print("chunk count policy difference PASS", flush=True)

decoder=framing.NoiseFrameDecoder()
with patch.object(framing.time,"time",return_value=100):
    check(decoder.decode(first) is None,"expiry first")
with patch.object(framing.time,"time",return_value=161):
    check(decoder.decode(second) is None,"expired assembly must not complete")
print("Python expiry on next decode PASS (C++ owner clock separate)", flush=True)

# Only test-generated keys and bytes, through process pipes. Never log ciphertext or keys.
p=subprocess.Popen([BIN,"session"],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
def take():
    line=p.stdout.readline()
    check(bool(line) and len(line)<=2*1024*1024+1,"bounded fixture response")
    return line.strip()
def send(data):
    p.stdin.write(data.hex()+"\n")
    p.stdin.flush()
try:
    responder=NoiseXXResponder(payload=b"awl-synthetic")
    responder.initialize()
    send(responder.read_message1_and_write_message2(bytes.fromhex(take())))
    responder.read_message3(bytes.fromhex(take()))
    tx,rx=responder.split()
    for size in (1,257,8192):
        payload=bytes(i % 251 for i in range(size))
        send(tx.encrypt_with_ad(b"",payload))
        check(rx.decrypt_with_ad(b"",bytes.fromhex(take()))==payload,"authenticated echo")
    print("synthetic Python responder/C++ initiator handshake and three authenticated echoes PASS",flush=True)
    valid=tx.encrypt_with_ad(b"",b"synthetic")
    send(valid[:-1]+bytes([valid[-1]^1]))
    check(take()=="tamper-rejected","tamper rejected")
    send(valid)
    check(take()=="poisoned-reject","poisoned state")
    p.stdin.close()
    check(p.wait(timeout=10)==0,"session exit")
    print("authenticated tamper and poison persistence PASS",flush=True)
finally:
    if p.poll() is None:
        p.kill()
        p.wait()
print("MuseResearch: all offline fixture assertions passed",flush=True)
