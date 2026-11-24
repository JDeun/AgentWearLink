# Meta Wearables DAT iOS: upstream refresh and AWL gap review (2026-10-31)

## Sources and reproducibility
- Upstream: https://github.com/meta/meta-wearables-dat-ios (also linked via facebook/meta-wearables-dat-ios)
- Upstream main observed: `bbae597cd1c748cd29b9375a1624a8d75b1c9e14` (2026-10-09 release commit).
- Changelog: https://github.com/meta/meta-wearables-dat-ios/blob/main/CHANGELOG.md
- AgentWearLink local pin: `Adapters/MetaDAT/Package.swift`, `1f38beecba83c4c8b5e343540f9cd615323ab19a`. The pin is the DAT 1.0.0-era revision; distinguish it from the latest upstream main and tagged artifact.
- Historical AWL cross-audit `docs/meta-dat-audit.md` dated 2026-10-06; `Adapters/MetaDAT/INTEGRATION.md` states pinned 1.0.0.
- The public upstream provides a precompiled binary XCFramework plus samples/docs. A GitHub compare from the AWL pinned commit to main reports 'No common ancestor'; a tree-path diff is not equivalent to an API/source semantic diff.

## Chronology of relevant upstream changes
| Version | Published | Change | AWL consequence |
|---|---|---|---|
| 0.8.0 | 2026-06-25 | Wi-Fi transport, DAT error model | Current transport/error assumptions need hardware checks |
| 0.9.0 | 2026-08-03 | iOS minimum 17.2, consolidated Camera, listener token bag, deterministic stopped session streams | AWL already requires iOS 17.2 and uses Camera lifecycle |
| 1.0.0 | 2026-09-24 | Experimental Inputs, Motion, Speech, Voice Invocation, standalone Photo and camera-associated PCM audio; battery/charging/worn/hinge/thermal and registration/deep link APIs | Existing AWL code adopts Speech, Inputs, Voice, Photo; Motion/health and raw camera PCM not implemented |
| 1.0.1 | 2026-10-09 | Changelog: **No developer-facing changes**; release commit updates changelog, metadata, sample package references | Evaluate 1.0.1 pin update as low-risk candidate, **not** zero-risk without binary/simulator tests |

Meta README documents default-enabled analytics and SDK crash capture, with opt-out configuration under `MWDAT.Analytics.OptOut` and `MWDAT.CrashReporting.OptOut`. AWL `Adapters/MetaDAT/TestApp/App/Info.plist` currently has MWDAT app ID, token, team ID, scheme but neither opt-out key. This is a concrete privacy policy decision, not a finding of misconduct.

## Newly useful upstream implementation evidence
1. `samples/BirdSpotter/BirdSpotter/Data/Dat/DatGlassesVoiceRepository.swift`: VoiceInvocationsStream is independent of DeviceSession. Awaits registration, watches roster and link events, acknowledges launch promptly and reopens channel on error with exponential backoff 0.5–30s. **Potential AWL test improvements**: cold launch, link changed after roster publication, channel failure with no roster change, exactly-once acknowledgement and reconnect. Avoid copying code without license review.
2. `samples/BirdSpotter/BirdSpotter/Data/Dat/DatGlassesSessionRepository.swift`: one owner of SDK session and Camera/Inputs/Motion/Speech/Display; capability revival tasks and active device state listeners. **AWL** should preserve existing actor/generation fencing rather than introduce a second ownership graph.
3. `samples/BirdSpotter/BirdSpotter/Data/Audio/GlassesMicrophoneSource.swift`: microphone rides the **Camera Stream**; waits 5s for first packet, then fails `unavailable` so a distinct phone-microphone fallback may be selected. **AWL** must not call this a standalone microphone; `rawAudioInput` capability must not be advertised until media permission, concrete PCM bridge, target deployment policy and tests are satisfied.
4. `plugins/mwdat-ios/skills/audio-streaming/SKILL.md`: PCM sample rates 16/44.1/48kHz; camera + microphone permission and Developer Center approval; video/audio share Stream lifecycle. No deterministic mock audio injection API documented.
5. `plugins/mwdat-ios/skills/inputs/SKILL.md`: Inputs auto-start on add after session started; 64-event newest buffer; no runtime Permission enum, approval required; event handling should be bounded.
6. `plugins/mwdat-ios/skills/motion/SKILL.md`: samples 5/10/15/24/30/60Hz, 256 newest, timestamp device monotonic, optional accelerometer/gyro/magnetometer/orientation; no runtime Permission enum.
7. `plugins/mwdat-ios/skills/voice-invocations/SKILL.md`: register in Developer Center, independent stream, send one acknowledgement for every invocation, retain listener tokens.
8. `plugins/mwdat-ios/skills/live-debugging-mcp/SKILL.md`: read-only DAT Inspector evidence flow including connection status, SDK state, readiness, device path, event digest and **redacted** diagnostic bundle.
9. README: 17 official skills plus `AGENTS.md`, Cursor/Copilot and hosted unauthenticated docs MCP `https://mcp.developer.meta.com/wearables`, usable to support development. They are **documentation aids**, not production SDK capabilities.

## AWL comparison and recommendations
| Priority | Gap / opportunity | Suggested action | Gate |
|---|---|---|---|
| P0 | Release drift: pinned 1.0.0 vs public 1.0.1 | Verify tagged commit vs current pinned API, XCFramework and app-hosted simulator build; upgrade only after green gates | Full iOS Xcode host |
| P0 | Telemetry defaults | Determine operator privacy policy; configure analytics/crash opt-out explicitly or document explicit consent, verify final built Info.plist | App-hosted plist and runtime |
| P0 | Voice invocation cold launch/link race | Extend existing tests with channel drop while device roster unchanged; test registration reopening, ack exactly once; preserve current AWL fencing | MockDeviceKit + physical |
| P1 | First camera PCM frame | Build opt-in experimental camera-audio adapter only after permission, distribution policy and 5s first-frame watchdog; bounded queue, proper teardown and explicit hardware evidence | Beta/dev only |
| P1 | Display and richer button input | AWL currently imports MWDATInputs and handles select; map commands/display using typed DeviceAction only if supported and approved | #633/#636 |
| P2 | IMU Motion | Only add if navigation/context use-case proves valuable, keep optional capability with 256 bounded queue and sampling controls | Motion mock/physical |
| P1 | Device health state | Battery/charging/don/hinge/thermal and immediate DeviceState listener may improve readiness and safe capture admission | Mock state + physical |
| P1 | Diagnostics | Evaluate read-only DAT Inspector MCP, redacted bundles, explicit credentials/secrets exclusion | Security review |

## Decision and non-claims
**Decision:** AWL existing Core architecture and Meta DAT integration should be retained. Prioritize dependency revalidation, telemetry controls, voice invocation robustness and deterministic hardware-oriented test gaps. Do not blindly adopt all sample code, assert experimental features may ship, or infer raw PCM capability from DAT Speech. The upstream 1.0.1 release carries no declared developer-facing change, but the expanded docs and BirdSpotter sample offer directly actionable code-level patterns. No Xcode build, iPhone/glasses physical run, full framework binary diff, or upstream issue triage was executed in this desk review.
