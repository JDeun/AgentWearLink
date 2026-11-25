// AWL research-only synthetic host fixture driver. No sockets, credentials or device IO.
#include <xplat/noise/core/InitiatorHandshake.h>
#include <xplat/noise/core/PsaCryptoBackend.h>
#include <xplat/noise/core/Transport.h>
#include <xplat/noise/core/TransportFrameCodec.h>
#include <array>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>
namespace n = musegadgets::noise::core;
using Bytes = std::vector<uint8_t>;
constexpr size_t limit = 1024 * 1024;
void require(bool ok, const char* label) {
  if (!ok) { std::cerr << "fixture failed: " << label << '\n'; std::exit(2); }
}
n::ByteSpan out(Bytes& x) { return {x.data(), x.size()}; }
n::ConstByteSpan in(const Bytes& x) { return {x.data(), x.size()}; }
int digit(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  return -1;
}
Bytes read(const std::string& line) {
  require(line.size() <= 2 * limit && line.size() % 2 == 0, "input bound");
  Bytes b(line.size() / 2);
  for (size_t i=0; i<b.size(); ++i) {
    int hi=digit(line[2*i]), lo=digit(line[2*i+1]);
    require(hi>=0 && lo>=0, "hex");
    b[i]=static_cast<uint8_t>(16*hi+lo);
  }
  return b;
}
Bytes next() { std::string l; require(bool(std::getline(std::cin,l)), "input EOF"); return read(l); }
void emit(n::ConstByteSpan b, const char* prefix="") {
  static constexpr char hex[]="0123456789abcdef";
  std::cout << prefix;
  for(size_t i=0;i<b.size();++i) std::cout << hex[b[i]>>4] << hex[b[i]&15];
  std::cout << std::endl;
}
int main(int argc,char**argv) {
  require(argc==2, "mode");
  std::string mode=argv[1];
  if(mode=="encode") {
    Bytes payload=next(), scratch(n::OrderedTransportFramer::kMaxEncodedFrameSize);
    n::OrderedTransportFramer framer;
    framer.setNextChunkIdForTesting(7);
    require(framer.StartOutboundMessage(in(payload)).ok(),"start outbound");
    while(framer.HasOutboundMessage()) {
      auto x=framer.EncodeNextOutboundFrame(out(scratch));
      require(x.ok(),"encode");
      emit({scratch.data(),x.size()});
    }
  } else if(mode=="scan") {
    Bytes scratch(limit);
    std::string line;
    while(std::getline(std::cin,line)) {
      auto bytes=read(line);
      require(bytes.size()<=128,"scan input bound");
      n::OrderedTransportFramer framer;
      auto x=framer.DecodeAndAppendInboundFrame(in(bytes),out(scratch));
      if(x.frame_status==n::InboundFrameStatus::Violation) std::cout << "rejected" << std::endl;
      else if(!x.status.ok()) std::cout << "resource" << std::endl;
      else if(x.frame_status==n::InboundFrameStatus::Complete) std::cout << "complete" << std::endl;
      else std::cout << "partial" << std::endl;
    }
  } else if(mode=="decode" || mode=="decode-small") {
    n::OrderedTransportFramer framer;
    Bytes scratch(mode=="decode-small"?1:limit);
    std::string line;
    while(std::getline(std::cin,line)) {
      auto frame=read(line);
      auto x=framer.DecodeAndAppendInboundFrame(in(frame),out(scratch));
      if(x.frame_status==n::InboundFrameStatus::Violation) std::cout << "violation" << std::endl;
      else if(!x.status.ok()) std::cout << "resource" << std::endl;
      else if(x.frame_status==n::InboundFrameStatus::Complete) emit({scratch.data(),x.size},"complete:");
      else std::cout << "more" << std::endl;
    }
  } else if(mode=="session") {
    n::PsaCryptoBackend backend;
    n::InitiatorHandshake hs(backend);
    Bytes scratch(65536), peer(256);
    auto m1=hs.WriteMessage1(out(scratch));
    require(m1.ok(),"message1");
    emit({scratch.data(),m1.size()});
    auto m2=next();
    size_t peerSize=0;
    require(hs.ReadMessage2(in(m2),out(peer),peerSize).ok(),"message2");
    const std::string expected="awl-synthetic";
    require(peerSize==expected.size() && std::string(peer.begin(),peer.begin()+peerSize)==expected,"synthetic peer payload");
    auto m3=hs.WriteMessage3(n::ConstByteSpan(),out(scratch));
    require(m3.ok(),"message3");
    emit({scratch.data(),m3.size()});
    n::SecretArray<n::Transport::kKeySize> send, recv;
    require(hs.Finalize(send.span(),recv.span()).ok(),"finalize");
    n::Transport tr(backend,send.span(),recv.span());
    require(tr.status().ok(),"transport");
    for(int i=0;i<3;++i) {
      auto cipher=next();
      auto opened=tr.Open(in(cipher),out(scratch));
      require(opened.ok(),"open");
      Bytes result(opened.size()+n::Transport::kTagSize);
      auto sealed=tr.Seal({scratch.data(),opened.size()},out(result));
      require(sealed.ok(),"seal");
      emit({result.data(),sealed.size()});
    }
    auto corrupt=next();
    require(!tr.Open(in(corrupt),out(scratch)).ok()&&tr.isReceivePoisoned(),"tamper poison");
    std::cout << "tamper-rejected" << std::endl;
    auto original=next();
    require(!tr.Open(in(original),out(scratch)).ok()&&tr.isReceivePoisoned(),"poison remains");
    std::cout << "poisoned-reject" << std::endl;
  } else require(false,"unknown mode");
}
