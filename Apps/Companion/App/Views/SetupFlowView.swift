import AgentWearLinkCore
import SwiftUI
import UIKit

/// First-run setup. Shown until setup completes, then never again.
struct SetupFlowView: View {
    @EnvironmentObject private var runtime: CompanionRuntime

    /// Pairing succeeded but "다음" not tapped yet: show step 4 as done.
    private var displayedProgress: SetupProgress {
        var progress = runtime.setup
        if runtime.pairing == .succeeded { progress.complete(.gateway) }
        return progress
    }

    var body: some View {
        AnchoredScrollView(scrollsToBottom: true) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("처음 설정")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(Theme.text)
                    Text("한 번만 하면 돼요 · \(runtime.setup.position)/\(SetupStep.allCases.count)단계")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                }
                .padding(.top, 12)

                if let step = runtime.setup.current {
                    Card {
                        currentStep(step)
                            .padding(20)
                    }
                    .id(step)
                    .transition(.opacity)
                }

                StepList(progress: displayedProgress, current: runtime.setup.current)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
            .animation(.easeInOut(duration: 0.25), value: runtime.setup)
        }
        .background(Theme.background.ignoresSafeArea())
    }

    @ViewBuilder
    private func currentStep(_ step: SetupStep) -> some View {
        switch step {
        case .metaRegistration: MetaRegistrationStep()
        case .microphone: MicrophoneStep()
        case .tailscale: TailscaleStep()
        case .gateway: GatewayStep()
        case .practice: PracticeStep()
        }
    }
}

private struct StepList: View {
    let progress: SetupProgress
    let current: SetupStep?

    var body: some View {
        Card {
            VStack(spacing: 0) {
                ForEach(SetupStep.allCases) { step in
                    let state = stepState(step)
                    HStack(spacing: 14) {
                        ZStack {
                            Circle().fill(background(state))
                            if state == .done {
                                Image(systemName: "checkmark").font(.footnote.weight(.bold))
                            } else {
                                Text(verbatim: "\(step.number)").font(.footnote.weight(.bold))
                            }
                        }
                        .foregroundStyle(foreground(state))
                        .frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            StepTitle(step: step)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(state == .upcoming ? Theme.tertiary : Theme.text)
                            StepDetail(step: step)
                                .font(.footnote)
                                .foregroundStyle(Theme.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private func stepState(_ step: SetupStep) -> SetupProgress.StepState {
        if progress.completed.contains(step) { return .done }
        return step == current ? .current : .upcoming
    }

    private func background(_ state: SetupProgress.StepState) -> Color {
        switch state {
        case .done: Color(hex: 0x173A2B)
        case .current: Theme.waitingBackground
        case .upcoming: Color(hex: 0x1C222C)
        }
    }

    private func foreground(_ state: SetupProgress.StepState) -> Color {
        switch state {
        case .done: Theme.ok
        case .current: Theme.accent
        case .upcoming: Theme.tertiary
        }
    }
}

/// One name per step, used both in the list and as the card title.
private struct StepTitle: View {
    let step: SetupStep
    var body: some View {
        switch step {
        case .metaRegistration: Text("Meta AI 앱에서 허용하기")
        case .microphone: Text("안경 마이크 허용하기")
        case .tailscale: Text("Tailscale 항상 켜기")
        case .gateway: Text("게이트웨이 연결하기")
        case .practice: Text("호출 연습하기")
        }
    }
}

private struct StepDetail: View {
    let step: SetupStep
    var body: some View {
        switch step {
        case .metaRegistration: Text("이 앱이 Meta 안경을 쓸 수 있게 해요")
        case .microphone: Text("안경 마이크로 말을 들어요")
        case .tailscale: Text("밖에서도 게이트웨이에 닿게 해요")
        case .gateway: Text("QR 한 번이면 끝, 이후 자동 연결")
        case .practice: Text("안경으로 한 번 불러 확인해요")
        }
    }
}

private struct StepHeader: View {
    let step: SetupStep
    let message: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StepTitle(step: step)
                .font(.title2.weight(.bold))
                .foregroundStyle(Theme.text)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Notice: View {
    let text: LocalizedStringKey
    var color: Color = Theme.problem
    var icon = "exclamationmark.triangle"

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
        }
        .font(.footnote)
        .foregroundStyle(color)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: 1. Meta registration

private struct MetaRegistrationStep: View {
    @EnvironmentObject private var runtime: CompanionRuntime
    @State private var requested = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(
                step: .metaRegistration,
                message: "Meta AI 앱이 열리면 Agent Wear Link를 허용해 주세요. 허용하면 이 앱으로 자동으로 돌아와요."
            )
            switch runtime.metaConfiguration {
            case .notProvisioned:
                Notice(text: "이 빌드에는 Meta 등록 정보(Team ID, 콜백 스킴)가 없어요. local.companion.xcconfig를 채운 뒤 다시 빌드해 주세요.")
            case .failed:
                Notice(text: "Meta 연결 구성을 불러오지 못했어요. Meta AI 앱이 설치되어 있는지 확인해 주세요.")
            default:
                EmptyView()
            }
            PrimaryButton(
                title: requested ? "Meta AI 앱 다시 열기" : "Meta AI 앱 열기",
                systemImage: "arrow.up.forward.app",
                prominent: true
            ) {
                requested = true
                Task { await runtime.registerWithMeta() }
            }
            .disabled(runtime.metaConfiguration != .configured)
        }
    }
}

// MARK: 2. Microphone

private struct MicrophoneStep: View {
    @EnvironmentObject private var runtime: CompanionRuntime
    @State private var working = false

    private var glassesReady: Bool { runtime.signals.glasses == .connected }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(
                step: .microphone,
                message: "안경 마이크로 말을 들어요. 버튼을 누르면 Meta AI 앱에서 허용 여부를 물어요."
            )
            if runtime.signals.microphone == .denied {
                Notice(text: "마이크가 허용되지 않았어요. Meta AI 앱에서 Agent Wear Link의 마이크 권한을 켜 주세요.")
            } else if !glassesReady {
                Notice(text: "먼저 안경을 펼쳐 쓰고 iPhone 가까이 두세요. 안경이 연결되면 버튼을 누를 수 있어요.",
                       color: Theme.accent, icon: "eyeglasses")
            }
            PrimaryButton(title: "안경 마이크 허용하기", systemImage: "mic", prominent: true, isLoading: working) {
                working = true
                Task {
                    await runtime.requestMicrophone()
                    working = false
                }
            }
            .disabled(!glassesReady)
        }
    }
}

// MARK: 3. Tailscale

private struct TailscaleStep: View {
    @EnvironmentObject private var runtime: CompanionRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(
                step: .tailscale,
                message: "밖에서도 게이트웨이 컴퓨터에 닿으려면 이 iPhone에서 Tailscale이 항상 켜져 있어야 해요."
            )
            VStack(alignment: .leading, spacing: 10) {
                GuideLine(number: 1, text: "Tailscale 앱을 열고 설정으로 가요")
                GuideLine(number: 2, text: "VPN On Demand를 켜요")
                GuideLine(number: 3, text: "‘항상’ 또는 모든 Wi‑Fi·셀룰러에서 연결을 선택해요")
            }
            Notice(text: "이 앱은 Tailscale 상태를 직접 확인하거나 켤 수 없어요. 연결이 끊기면 원인과 해결 방법을 보여 드려요.",
                   color: Theme.secondary, icon: "info.circle")
            PrimaryButton(title: "Tailscale 열기", systemImage: "arrow.up.forward.app") {
                ExternalApps.openTailscale()
            }
            PrimaryButton(title: "켜 두었어요", systemImage: "checkmark", prominent: true) {
                runtime.completeStep(.tailscale)
            }
        }
    }
}

private struct GuideLine: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: "\(number)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Theme.accent)
                .frame(minWidth: 22, minHeight: 22)
                .background(Theme.waitingBackground, in: Circle())
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: 4. Gateway

private struct GatewayStep: View {
    @EnvironmentObject private var runtime: CompanionRuntime
    private enum Mode { case scan, paste, manual }
    @State private var mode: Mode = Self.initialMode
    @State private var code = ""
    @State private var address = ""
    @State private var token = ""
    @State private var spokenName = ""
    @State private var cameraFailure: QRScannerView.Failure?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch runtime.pairing {
            case .connecting, .waitingForApproval:
                waiting
            case .succeeded:
                succeeded
            case let .failed(error):
                failed(error)
            case .idle:
                entry
            }
        }
    }

    private static var initialMode: Mode {
        #if DEBUG
        switch CompanionPreviewFixture.gatewayMode {
        case .paste: return .paste
        case .manual: return .manual
        case .scan, .none: return .scan
        }
        #else
        return .scan
        #endif
    }

    private var entry: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                switch mode {
                case .scan: Text("게이트웨이 컴퓨터의 QR을 찍어 주세요")
                case .paste: Text("설정 코드를 붙여넣어 주세요")
                case .manual: Text("주소를 직접 입력해 주세요")
                }
            }
            .font(.title2.weight(.bold))
            .foregroundStyle(Theme.text)
            .fixedSize(horizontal: false, vertical: true)
            Text("게이트웨이 컴퓨터의 터미널에서 `openclaw qr`을 실행하면 주소와 1회용 코드가 담긴 QR과 설정 코드가 나와요.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker(selection: $mode) {
                Text("QR 찍기").tag(Mode.scan)
                Text("코드 붙여넣기").tag(Mode.paste)
                Text("직접 입력").tag(Mode.manual)
            } label: {
                Text("연결 방법")
            }
            .pickerStyle(.segmented)

            switch mode {
            case .scan: scanner
            case .paste: pasteForm
            case .manual: manualForm
            }

            fingerprintNote
        }
    }

    @ViewBuilder private var scanner: some View {
        if let cameraFailure {
            Notice(text: cameraFailure == .denied
                   ? "카메라 권한이 없어요. 설정에서 허용하거나 코드를 붙여넣어 주세요."
                   : "이 기기에서 카메라를 쓸 수 없어요. 코드를 붙여넣거나 주소를 직접 입력해 주세요.")
        } else if Self.usesScannerPlaceholder {
            // Screenshot fixtures: no camera, no permission prompt.
            ScannerFrame { Color.black }
        } else {
            ScannerFrame {
                QRScannerView(
                    onCode: { runtime.pair(setupCode: $0) },
                    onFailure: { cameraFailure = $0 }
                )
            }
        }
    }

    private static var usesScannerPlaceholder: Bool {
        #if DEBUG
        return CompanionPreviewFixture.isActive
        #else
        return false
        #endif
    }

    private var pasteForm: some View {
        VStack(spacing: 12) {
            TextField(text: $code, axis: .vertical) { Text("설정 코드") }
                .lineLimit(2...4)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .fieldStyle()
            PrimaryButton(title: "붙여넣기", systemImage: "doc.on.clipboard") {
                code = UIPasteboard.general.string ?? ""
            }
            PrimaryButton(title: "연결", prominent: true) {
                runtime.pair(setupCode: code)
                code = ""
            }
            .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var manualForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(text: $address) { Text("주소 (예: gateway-host.tailnet.ts.net)") }
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .fieldStyle()
            SecureField(text: $token) { Text("1회용 연결 코드") }
                .textInputAutocapitalization(.never)
                .fieldStyle()
            Text("코드는 이번 연결에만 쓰고 저장하지 않아요. 승인된 뒤에는 이 기기 전용 인증으로 자동 연결돼요.")
                .font(.caption)
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            PrimaryButton(title: "연결", prominent: true) {
                runtime.pair(address: address, oneTimeToken: token)
                token = ""
            }
            .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var fingerprintNote: some View {
        let short = Text(verbatim: DeviceFingerprint.short(runtime.deviceID))
            .font(.footnote.monospaced().weight(.semibold))
            .foregroundColor(Theme.accent)
        return Text("연결하면 게이트웨이에 승인 요청이 가요. 승인할 때 이 기기 지문 \(short)이 맞는지 확인하세요.")
            .font(.footnote)
            .foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                ProgressView().tint(Theme.accent)
                if runtime.pairing == .connecting {
                    Text("게이트웨이에 연결하는 중").font(.title3.weight(.bold))
                } else {
                    Text("승인을 기다리고 있어요").font(.title3.weight(.bold))
                }
            }
            .foregroundStyle(Theme.text)
            VStack(spacing: 6) {
                Text("이 기기 지문").font(.caption).foregroundStyle(Theme.secondary)
                Text(verbatim: DeviceFingerprint.short(runtime.deviceID))
                    .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            ApprovalInstructions(
                fingerprint: DeviceFingerprint.short(runtime.deviceID),
                requestID: runtime.pendingRequestID
            )
            PrimaryButton(title: "취소") { runtime.cancelPairing() }
        }
    }

    @ViewBuilder
    private func failed(_ error: CompanionRuntime.PairingError) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                failureTitle(error).font(.title3.weight(.bold))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.problem)
            }
            .foregroundStyle(Theme.text)
            failureText(error)
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            switch error {
            case .expiredCode, .invalidCode:
                CommandRow(command: "openclaw qr")
                PrimaryButton(title: "새 QR 찍기", systemImage: "qrcode.viewfinder", prominent: true) {
                    runtime.resetPairing()
                }
            case .network:
                if runtime.canRetryPairing {
                    PrimaryButton(title: "다시 시도", systemImage: "arrow.clockwise", prominent: true) {
                        runtime.retryPairing()
                    }
                }
                PrimaryButton(title: "Tailscale 열기", systemImage: "arrow.up.forward.app") {
                    ExternalApps.openTailscale()
                }
                PrimaryButton(title: "처음부터 다시") { runtime.resetPairing() }
            case .gateway, .rejected, .timedOut:
                if runtime.canRetryPairing {
                    PrimaryButton(title: "다시 시도", systemImage: "arrow.clockwise", prominent: true) {
                        runtime.retryPairing()
                    }
                }
                PrimaryButton(title: "처음부터 다시") { runtime.resetPairing() }
            case .invalidAddress, .insecureAddress:
                PrimaryButton(title: "주소 다시 입력", prominent: true) { runtime.resetPairing() }
            }
        }
    }

    private var succeeded: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text("\(runtime.gatewayLabel)에 연결됐어요").font(.title3.weight(.bold))
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
            }
            .foregroundStyle(Theme.text)
            Text("다음부터는 자동으로 다시 연결돼요.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
            if !runtime.settings.agentName.isEmpty {
                LabeledContent {
                    Text(verbatim: runtime.settings.agentName).foregroundStyle(Theme.text)
                } label: {
                    Text("에이전트").foregroundStyle(Theme.secondary)
                }
                .font(.subheadline)
            }
            if WakePhrases.prefersKorean, WakePhrases.needsPronunciation(agentName: runtime.settings.agentName) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("‘\(runtime.settings.agentName)’, 한국어로는 어떻게 부르세요?")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField(text: $spokenName) { Text("예: 한글로 쓴 이름 (선택)") }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .fieldStyle()
                    Text("안경의 음성 인식은 이름을 한글로 받아 적어요. 적어 두면 그 이름으로도 부를 수 있어요.")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            PrimaryButton(title: "다음", prominent: true) {
                let spoken = spokenName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !spoken.isEmpty { runtime.settings.spokenName = spoken }
                runtime.completeStep(.gateway)
            }
        }
    }

    @ViewBuilder
    private func failureTitle(_ error: CompanionRuntime.PairingError) -> some View {
        switch error {
        case .expiredCode: Text("설정 코드가 만료됐어요")
        case .invalidCode: Text("설정 코드를 읽지 못했어요")
        case .network: Text("게이트웨이 컴퓨터에 닿지 않아요")
        case .gateway: Text("게이트웨이가 연결을 거절했어요")
        case .rejected: Text("승인되지 않았어요")
        case .timedOut: Text("승인을 너무 오래 기다렸어요")
        case .invalidAddress: Text("주소 형식이 올바르지 않아요")
        case .insecureAddress: Text("이 주소는 쓸 수 없어요")
        }
    }

    @ViewBuilder
    private func failureText(_ error: CompanionRuntime.PairingError) -> some View {
        switch error {
        case .expiredCode, .invalidCode:
            Text("게이트웨이 컴퓨터에서 아래 명령으로 새 QR을 만든 뒤 다시 찍어 주세요.")
        case .network:
            Text("이 iPhone의 Tailscale이 켜져 있는지, 컴퓨터가 깨어 있는지 확인해 주세요.")
        case .gateway:
            Text("게이트웨이 컴퓨터에서 OpenClaw가 실행 중인지 확인해 주세요.")
        case .rejected:
            Text("요청이 거절됐거나 권한이 부족해요. 다시 요청해 주세요.")
        case .timedOut:
            Text("10분 안에 승인되지 않았어요. 다시 요청해 주세요.")
        case .invalidAddress:
            Text("예: gateway-host.tailnet.ts.net")
        case .insecureAddress:
            Text("암호화되지 않은 공개 주소는 쓸 수 없어요. Tailscale 주소를 입력해 주세요.")
        }
    }
}

/// Camera preview area with viewfinder corners.
private struct ScannerFrame<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                Image(systemName: "viewfinder")
                    .font(.system(size: 150, weight: .ultraLight))
                    .foregroundStyle(Theme.accent.opacity(0.8))
                    .accessibilityHidden(true)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.4), lineWidth: 1)
            )
            .accessibilityElement()
            .accessibilityLabel(Text("카메라 미리보기"))
    }
}

// MARK: 5. Call practice

private struct PracticeStep: View {
    @EnvironmentObject private var runtime: CompanionRuntime

    private var name: String {
        runtime.settings.effectiveWakePhrases.first ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(
                step: .practice,
                message: "안경을 쓰고 아래처럼 말해 보세요. 들은 말과 호출 여부가 여기에 바로 보여요."
            )
            Text("“\(name), 안녕”")
                .font(.title.weight(.bold))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.vertical, 8)

            VStack(alignment: .leading, spacing: 8) {
                Text("들은 말").font(.caption).foregroundStyle(Theme.secondary)
                if let transcript = runtime.practice.transcript {
                    Text(verbatim: transcript).font(.body).foregroundStyle(Theme.text)
                } else if runtime.isListening {
                    Text("듣는 중…").font(.body).foregroundStyle(Theme.tertiary)
                } else {
                    Text("안경을 기다리는 중…").font(.body).foregroundStyle(Theme.tertiary)
                }
                if let matched = runtime.practice.matched {
                    Label {
                        matched ? Text("호출됐어요 — 에이전트에게 보냈어요") : Text("호출 이름으로 시작하지 않아 무시했어요")
                    } icon: {
                        Image(systemName: matched ? "checkmark.circle.fill" : "xmark.circle")
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(matched ? Theme.ok : Theme.problem)
                }
                if runtime.practice.matched == false,
                   let heard = runtime.practice.transcript.flatMap(WakePhrases.candidate(fromIgnored:)) {
                    PrimaryButton(title: "‘\(heard)’\(KoreanParticle.object(after: heard)) 호출 이름으로 추가", systemImage: "plus") {
                        runtime.addPracticeWakePhrase(heard)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Notice(text: "연습도 실제 요청으로 보내져서 에이전트가 답하고 대화 기록에도 남아요.",
                   color: Theme.secondary, icon: "info.circle")

            PrimaryButton(title: "완료", prominent: true) { runtime.finishSetup() }
                .disabled(runtime.practice.matched != true)
            Button {
                runtime.skipStep(.practice)
            } label: {
                Text("나중에 하기")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .foregroundStyle(Theme.secondary)
        }
    }
}

extension View {
    func fieldStyle() -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(Theme.text)
    }
}
