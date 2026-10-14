import SwiftUI
import UIKit

/// First-run setup. Shown until setup completes, then never again.
struct SetupFlowView: View {
    @EnvironmentObject private var runtime: CompanionRuntime

    var body: some View {
        AnchoredScrollView(scrollsToBottom: true) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("처음 설정")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(Theme.text)
                    Text("처음 한 번만 · \(runtime.setup.position)/\(SetupStep.allCases.count)단계")
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

                StepList(progress: runtime.setup)
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

    var body: some View {
        Card {
            VStack(spacing: 0) {
                ForEach(SetupStep.allCases) { step in
                    let state = progress.state(of: step)
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

private struct StepTitle: View {
    @EnvironmentObject private var runtime: CompanionRuntime
    let step: SetupStep
    var body: some View {
        switch step {
        case .metaRegistration: Text("메타 안경 등록")
        case .microphone: Text("마이크 권한")
        case .tailscale: Text("Tailscale 자동 연결")
        case .gateway:
            let name = runtime.settings.gatewayDisplayName
            if name.isEmpty { Text("게이트웨이 연결") } else { Text("\(name) 연결") }
        case .practice: Text("호출 연습")
        }
    }
}

private struct StepDetail: View {
    let step: SetupStep
    var body: some View {
        switch step {
        case .metaRegistration: Text("Meta AI 앱에서 허용")
        case .microphone: Text("안경 마이크로 말씀을 듣습니다")
        case .tailscale: Text("VPN On Demand를 켜서 항상 연결")
        case .gateway: Text("QR 한 번이면 끝, 이후 자동 재연결")
        case .practice: Text("안경으로 한 번 불러서 확인")
        }
    }
}

private struct StepHeader: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
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
                title: "Meta AI 앱 등록 필요",
                message: "Meta AI 앱에서 Agent Wear Link를 허용해 주세요. 허용하면 이 앱으로 자동으로 돌아옵니다."
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
                title: requested ? "Meta AI 앱 다시 열기" : "Meta AI 앱에서 등록하기",
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(
                title: "안경 마이크 허용",
                message: "안경 마이크로 말씀을 듣습니다. 안경을 쓰고 iPhone 가까이 둔 뒤 버튼을 누르면 Meta AI 앱에서 허용을 묻습니다."
            )
            if runtime.signals.microphone == .denied {
                Notice(text: "마이크가 허용되지 않았어요. Meta AI 앱에서 Agent Wear Link의 마이크 권한을 켜 주세요.")
            } else if runtime.signals.glasses != .connected {
                Notice(text: "안경이 아직 연결되지 않았어요. 안경을 펼쳐 쓰면 자동으로 연결됩니다.",
                       color: Theme.accent, icon: "eyeglasses")
            }
            PrimaryButton(title: "안경 마이크 허용하기", systemImage: "mic", prominent: true, isLoading: working) {
                working = true
                Task {
                    await runtime.requestMicrophone()
                    working = false
                }
            }
        }
    }
}

// MARK: 3. Tailscale

private struct TailscaleStep: View {
    @EnvironmentObject private var runtime: CompanionRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(
                title: "Tailscale을 항상 연결해 두세요",
                message: "밖에서도 게이트웨이에 닿으려면 이 iPhone의 Tailscale이 켜져 있어야 해요."
            )
            VStack(alignment: .leading, spacing: 10) {
                GuideLine(number: 1, text: "Tailscale 앱을 열고 설정으로 이동")
                GuideLine(number: 2, text: "VPN On Demand를 켜기")
                GuideLine(number: 3, text: "‘항상 연결’ 또는 모든 Wi‑Fi·셀룰러에서 연결 선택")
            }
            Notice(text: "이 앱은 Tailscale 상태를 직접 확인하거나 켤 수 없어요. 연결이 끊기면 원인 후보와 다시 확인 버튼을 보여 드려요.",
                   color: Theme.secondary, icon: "info.circle")
            PrimaryButton(title: "다음", prominent: true) {
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
                .frame(width: 22, height: 22)
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
    @State private var cameraFailure: QRScannerView.Failure?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch runtime.pairing {
            case .connecting, .waitingForApproval:
                waiting
            case .succeeded:
                succeeded
            case .idle, .failed:
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
            StepHeader(
                title: "게이트웨이 컴퓨터의 QR을 찍어 주세요",
                message: "게이트웨이 컴퓨터에서 openclaw qr을 실행하면 주소와 1회용 연결 코드가 담긴 QR이 나와요. 토큰을 직접 입력할 필요가 없어요."
            )
            if case let .failed(error) = runtime.pairing {
                Notice(text: failureText(error))
            }
            Picker(selection: $mode) {
                Text("QR 찍기").tag(Mode.scan)
                Text("코드 붙여넣기").tag(Mode.paste)
                Text("주소 직접 입력").tag(Mode.manual)
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
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black)
                .frame(height: 260)
                .overlay(
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 64))
                        .foregroundStyle(Theme.accent.opacity(0.7))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(0.6), lineWidth: 2)
                )
                .accessibilityLabel(Text("카메라 미리보기"))
        } else {
            QRScannerView(
                onCode: { runtime.pair(setupCode: $0) },
                onFailure: { cameraFailure = $0 }
            )
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.6), lineWidth: 2)
            )
            .accessibilityLabel(Text("카메라 미리보기"))
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
            HStack(spacing: 10) {
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
    }

    private var manualForm: some View {
        VStack(spacing: 12) {
            TextField(text: $address) { Text("주소 (예: gateway-host.tailnet.ts.net)") }
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .fieldStyle()
            SecureField(text: $token) { Text("1회용 토큰") }
                .textInputAutocapitalization(.never)
                .fieldStyle()
            Text("토큰은 이번 연결에만 쓰고 저장하지 않아요. 승인 후에는 이 기기 전용 인증으로 자동 연결됩니다.")
                .font(.caption)
                .foregroundStyle(Theme.tertiary)
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
                    Text("게이트웨이에서 승인을 기다리는 중").font(.title3.weight(.bold))
                }
            }
            .foregroundStyle(Theme.text)
            Text("OpenClaw 게이트웨이에서 새 기기 요청을 승인해 주세요. 요청의 기기 지문이 아래와 같은지 확인하세요.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                Text("이 기기 지문").font(.caption).foregroundStyle(Theme.secondary)
                Text(verbatim: DeviceFingerprint.short(runtime.deviceID))
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                    .textSelection(.enabled)
                Text(verbatim: DeviceFingerprint.grouped(runtime.deviceID))
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.tertiary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            PrimaryButton(title: "취소") { runtime.cancelPairing() }
        }
    }

    private var succeeded: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text("\(runtime.gatewayLabel) 연결 완료").font(.title3.weight(.bold))
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
            }
            .foregroundStyle(Theme.text)
            if !runtime.settings.agentName.isEmpty {
                Text("\(runtime.settings.agentName)에게 연결됐어요. 이후에는 자동으로 다시 연결됩니다.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
            }
            PrimaryButton(title: "다음", prominent: true) {
                runtime.completeStep(.gateway)
            }
        }
    }

    private func failureText(_ error: CompanionRuntime.PairingError) -> LocalizedStringKey {
        switch error {
        case .invalidCode: "설정 코드를 읽을 수 없어요. 게이트웨이 컴퓨터에서 QR을 새로 만들어 주세요."
        case .expiredCode: "설정 코드가 만료됐어요. 게이트웨이 컴퓨터에서 QR을 새로 만들어 주세요."
        case .invalidAddress: "주소 형식이 올바르지 않아요."
        case .insecureAddress: "암호화되지 않은 공개 주소는 쓸 수 없어요. Tailscale 주소를 입력해 주세요."
        case .network: "게이트웨이에 닿지 않아요. Tailscale이 켜져 있는지 확인해 주세요."
        case .gateway: "게이트웨이가 연결을 거절했어요."
        case .rejected: "승인되지 않았거나 권한이 부족해요. 다시 시도해 주세요."
        case .timedOut: "승인을 너무 오래 기다렸어요. 다시 시도해 주세요."
        }
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
                title: "안경으로 한 번 불러 보세요",
                message: "안경을 쓰고 아래처럼 말해 보세요. 들은 말과 호출 여부가 여기에 바로 보입니다."
            )
            Text(verbatim: "“\(name), 안녕”")
                .font(.title.weight(.bold))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity)
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
                        matched ? Text("호출됨 — 에이전트에게 보냈어요") : Text("호출 문구로 시작하지 않아 무시했어요")
                    } icon: {
                        Image(systemName: matched ? "checkmark.circle.fill" : "xmark.circle")
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(matched ? Theme.ok : Theme.problem)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

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
