# Muse video protocol, iOS/Android samples, and codec licensing (2026-10-31)

**Scope:** source/document inspection, not a measured video experiment. Previous audits focused on ESP32/Linux and missed the first-party iOS and Android sample applications. This is a material research correction.

## New first-party surfaces
- `ios/musegadgetstest/README.md`: native iOS 17+ sample, VideoToolbox H.264 encoder, Bonjour `_musevideo._tcp` discovery, Wi-Fi TCP stream, receiver-driven credits, latency and bitrate adaptation.
- `android/musegadgetstest/README.md`: Android hardware H.264 encoder; optional x264 or VP8 build; equivalent flow-control architecture.
- `protocols/VIDEO.md`: explicit **phone camera -> phone encoder -> Wi-Fi -> ESP32 decoder/display** direction. This is not the same as AWL's **wearable camera -> iPhone -> agent snapshot** direction.

## Protocol contract
- Gadget `hello` advertises version, supported codecs, display geometry, maximum and suggested frame size/rate/bitrate, ring buffer, playout budget and band configuration.
- Client `start` selects codec, geometry, fps, bitrate, playout and bands.
- Gadget `buffer` returns `free`, `received`, `shown`, `dropped`, `decode_ms`, optionally last-frame timing. **Receiver credits** gate sender bytes; drop/latency metrics support adaptive encoding.
- Designed for H.264 constrained baseline and optional VP8, 24–30fps, with decoder timing around 20–30ms/frame on targeted MCUs. These are upstream design parameters, **not AWL benchmark measurements**.
- Source sample apps are not the Muse BLE provisioning apps; video runs over LAN discovery/TCP and may require same-network reachability.

## Licensing
- Top-level repository mostly Apache-2.0, with separately licensed embedded decoders.
- Optional x264 is **not bundled**; sample app builds incorporating GPL-2.0 x264 trigger GPL distribution obligations unless separately commercially licensed. Do not copy optional x264 integration into a proprietary iOS app without legal review.
- libvpx VP8 is BSD-3-Clause plus patent grant; VideoToolbox hardware encoding is a different distribution path.
- Blender sample clips are fetched separately under CC BY 3.0 and are not SDK-licensed footage.
- Distinguish code licenses from Muse SDK token/service terms.

## AWL decisions
| Muse idea | Decision | Why |
|---|---|---|
| Receiver-advertised codec/capability limits | **Reference / #636** | Concrete model for per-device negotiated capabilities |
| Credit-based bounded media delivery and drop telemetry | **Prototype only for future streaming adapter / #635** | Avoid lossy media overwhelming control events |
| iOS VideoToolbox / Android hardware encoder | **Do not import now** | AWL's current Meta DAT vision path is a bounded still capture in the opposite direction |
| Optional x264 / codec-specific sources | **Exclude by default / #639** | Licensing, build complexity, no demonstrated use case |
| Phone-camera-to-ESP32-display mode | **Separate feature** | Not proof of glasses camera ingest or OpenClaw vision E2E |

## Research conclusion
Muse contains an additional mobile-to-device video architecture useful for future output devices, but it does not solve AWL's wearable-to-agent vision capture. A claim that Muse's video protocol can be directly reused for glasses image ingestion would reverse the data direction and is unsupported.

## Primary sources
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/protocols/VIDEO.md
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/ios/musegadgetstest/README.md
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/android/musegadgetstest/README.md
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/README.md
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/README.md
