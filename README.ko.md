# AgentWearLink

**웨어러블 디바이스와 AI 에이전트 런타임을 연결하는 오픈 상호운용성 레이어입니다.**

[English](README.md) · [아키텍처](docs/architecture.md) · [PRD](docs/PRD.md) · [테스트](docs/testing.md)

AgentWearLink(AWL)는 음성, 오디오, 카메라 스냅샷, 호출, 출력과 같은 웨어러블 기능을 교체 가능한 어댑터 뒤에서 정규화하고, 이를 기존 AI 에이전트 런타임에 연결합니다. AWL 자체가 모델·메모리·도구·RAG 같은 에이전트의 지능을 대신 구현하지 않습니다.

> **상태:** pre-alpha. Core와 OpenClaw 기반 구현 및 자동화 테스트는 진행되었으며, Ray-Ban Meta + iPhone 실기기 검증은 아직 진행 중입니다.

## 왜 AgentWearLink인가

웨어러블 연동은 흔히 특정 디바이스 SDK, 모델 제공자 또는 채팅 서비스에 강하게 결합됩니다. AWL은 이를 다음처럼 분리합니다.

```text
웨어러블 SDK          AgentWearLink Core          에이전트 런타임
────────────          ──────────────────          ───────────────
Meta DAT      ─────▶  정규화된 이벤트    ─────▶ OpenClaw
향후 SDK               capability                 향후 런타임
커스텀 디바이스         lifecycle/streaming        로컬/커스텀 에이전트
```

모델 선택, 메모리, 도구, RAG, MCP, 라우팅, 오케스트레이션은 연결된 에이전트 런타임이 계속 담당합니다.

## 첫 번째 레퍼런스 구성

- **웨어러블:** Ray-Ban Meta
- **휴대폰:** iPhone + Meta Wearables Device Access Toolkit(DAT)
- **에이전트:** Mac mini에서 실행되는 OpenClaw
- **사설 네트워크:** Tailscale
- **음성 출력:** `AVSpeechSynthesizer` 기반 iOS 기본 TTS
- **비전:** 사용자가 명시적으로 요청한 event-driven snapshot만 허용

Meta DAT, OpenClaw, Tailscale, Telegram, Apple TTS는 레퍼런스 통합이며 Core의 필수 의존성이 아닙니다.

## 현재 구현된 기능

- vendor-neutral capability / interaction contract
- deterministic interaction/runtime lifecycle
- bounded async streaming 및 SSE parser
- HTTP transport primitive
- OpenClaw native Gateway WebSocket transport
- OpenClaw device identity, challenge proof, pairing, RPC dispatch, streaming agent run, cancellation, reconnect supervision
- 읽기 전용 OpenClaw health probe
- 명시적 opt-in 방식의 실제 OpenClaw text E2E probe
- Meta DAT adapter boundary/scaffold
- 크기 제한 및 agent capability 선검사를 포함한 명시적 vision contract
- Apple host output package 및 `AVSpeechSynthesizer` bridge
- deterministic reliability regression test

실제 DAT 연동, Ray-Ban 오디오 라우팅, hands-free invocation, 실제 vision E2E는 실기기 검증 단계가 남아 있습니다.

## 패키지 구조

| 패키지 | 역할 |
| --- | --- |
| `AgentWearLinkCore` | capability, event, lifecycle, streaming, vision 등 공통 계약 |
| `AgentWearLinkOpenClaw` | OpenClaw Gateway/auth/RPC/agent 연동 |
| `AgentWearLinkMetaDAT` | Meta DAT adapter 경계 |
| `AgentWearLinkAppleOutput` | Apple host 음성 출력 lifecycle 및 기본 TTS bridge |

## 빠른 시작

개발 기준 Swift 5.10+, macOS 14+가 필요하며 레퍼런스 iOS host 기준은 iOS 17+입니다.

```bash
git clone https://github.com/JDeun/AgentWearLink.git
cd AgentWearLink
swift test
```

실제 OpenClaw 연결은 먼저 [읽기 전용 probe](docs/openclaw-probe.md)로 연결·인증·pairing을 확인하고, 실제 agent run을 발생시키는 P0-B 검증은 [mutating text probe](docs/openclaw-chat-probe.md)를 사용합니다.

## 핵심 설계 원칙

1. Vendor SDK 타입을 Core로 유출하지 않습니다.
2. AWL이 에이전트의 지능을 재구현하지 않습니다.
3. 지원하지 않는 capability를 광고하지 않습니다.
4. 카메라는 명시적 요청에서만 촬영하며 continuous vision을 기본값으로 사용하지 않습니다.
5. media/stream queue는 항상 bounded 상태를 유지합니다.
6. reconnect는 transport만 복구하며 결과가 불확실한 mutating request를 자동 재전송하지 않습니다.
7. credential과 device private key를 source control에 저장하지 않습니다.
8. 실제 두 번째 구현 필요성이 확인되기 전에는 추상화를 불필요하게 확대하지 않습니다.

## 로드맵

| 단계 | 목표 |
| --- | --- |
| P0-A | Meta DAT 실기기 검증 |
| P0-B | iPhone → Tailnet → OpenClaw text E2E |
| P0-C | 웨어러블 오디오 → agent → iOS TTS/audio |
| P0-D | DAT hands-free voice invocation |
| P1 | event-driven vision 실기기 E2E |
| P2 | reliability/privacy/recovery 실기기 검증 |
| P3 | 실제 수요에 기반한 추가 device/agent adapter |

구현 요구사항의 정본은 [docs/PRD.md](docs/PRD.md)입니다.

## 문서

전체 문서 구조는 [docs/README.md](docs/README.md)에서 확인할 수 있습니다. 주요 설계 결정은 [docs/adr](docs/adr)에 기록합니다.

## 기여

현재 pre-alpha 단계이므로 package boundary를 보존하고 가능한 변경에는 deterministic test를 포함해야 합니다. 자세한 내용은 [CONTRIBUTING.md](CONTRIBUTING.md)를 참고하십시오.

## 보안

credential, private device key, 사적인 media를 public issue에 첨부하지 마십시오. 보안 관련 안내는 [SECURITY.md](SECURITY.md)를 참고하십시오.

## 라이선스

Apache License 2.0을 적용합니다. 자세한 내용은 [LICENSE](LICENSE)를 참고하십시오.
