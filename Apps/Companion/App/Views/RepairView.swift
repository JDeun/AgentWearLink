import AgentWearLinkCore
import SwiftUI
import UIKit

/// The first broken hop: what is wrong, one action right under it, then
/// what to try.
struct RepairView: View {
    @EnvironmentObject private var runtime: CompanionRuntime
    @Environment(\.dismiss) private var dismiss
    let problem: AWLChainProblem

    var body: some View {
        let guide = RepairGuide(problem: problem)
        AnchoredScrollView(scrollsToBottom: true) {
            VStack(alignment: .leading, spacing: 16) {
                Card(background: Theme.problemBackground, radius: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        ProblemHeadline(
                            reason: problem.reason,
                            gatewayName: runtime.gatewayLabel,
                            agentName: runtime.agentLabel,
                            updateTarget: runtime.signals.updateTarget
                        )
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                        ProblemReasonText(reason: problem.reason, updateTarget: runtime.signals.updateTarget)
                            .font(.subheadline)
                            .foregroundStyle(Color(hex: 0xD9C3A5))
                            .fixedSize(horizontal: false, vertical: true)
                        if let checked = runtime.lastCheckAt {
                            Text("\(RelativeTime.string(checked)) 확인")
                                .font(.footnote)
                                .foregroundStyle(Color(hex: 0xD9C3A5).opacity(0.8))
                        }
                    }
                    .padding(20)
                }

                actionButton(guide.action)

                if problem.reason == .pairingPending {
                    Card {
                        ApprovalInstructions(
                            fingerprint: DeviceFingerprint.short(runtime.deviceID),
                            requestID: runtime.pendingRequestID
                        )
                        .padding(16)
                    }
                } else if !guide.causes.isEmpty {
                    Text("이렇게 해 보세요")
                        .font(.headline)
                        .foregroundStyle(Theme.text)
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(guide.causes.enumerated()), id: \.element) { index, cause in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(verbatim: "\(index + 1)")
                                        .font(.footnote.weight(.bold))
                                        .foregroundStyle(Theme.problem)
                                        .frame(minWidth: 22, minHeight: 22)
                                        .background(Theme.problemInner, in: Circle())
                                    CauseText(cause: cause)
                                        .font(.subheadline)
                                        .foregroundStyle(Theme.text)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(16)
                    }
                }

                if guide.showsTailscaleOnDemandHint {
                    Card(background: Theme.raised) {
                        VStack(alignment: .leading, spacing: 12) {
                            Label {
                                Text("Tailscale 앱에서 VPN On Demand를 켜 두면 이 문제가 거의 생기지 않아요. 이 앱은 Tailscale을 직접 켤 수 없어요.")
                                    .font(.footnote)
                                    .foregroundStyle(Theme.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "lightbulb").foregroundStyle(Theme.accent)
                            }
                            PrimaryButton(title: "Tailscale 열기", systemImage: "arrow.up.forward.app") {
                                ExternalApps.openTailscale()
                            }
                        }
                        .padding(14)
                    }
                }

                ChainListView(
                    rows: runtime.homeState.rows,
                    signals: runtime.signals,
                    agentName: runtime.settings.agentName,
                    gatewayName: runtime.gatewayLabel
                )
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(Text("연결 문제 해결"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Waiting for approval: notice it quickly, then go back by itself.
            guard problem.reason == .pairingPending else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await runtime.checkNow()
            }
        }
        .onChange(of: runtime.homeState.banner) { _, banner in
            // Fixed: go back to Home.
            if case let .problem(current) = banner, current == problem { return }
            dismiss()
        }
    }

    @ViewBuilder
    private func actionButton(_ action: AWLChainRepairAction?) -> some View {
        switch action {
        case .openAppSettings:
            PrimaryButton(title: "안경 마이크 허용하기", systemImage: "mic", prominent: true) {
                Task { await runtime.requestMicrophone() }
            }
        case .openMetaAIApp:
            PrimaryButton(title: "Meta AI 앱 열기", systemImage: "arrow.up.forward.app", prominent: true) {
                Task { await runtime.registerWithMeta() }
            }
        case .waitForApproval:
            PrimaryButton(title: "승인했어요, 다시 확인", systemImage: "arrow.clockwise", prominent: true,
                          isLoading: runtime.isChecking) {
                Task { await runtime.checkNow() }
            }
        case .runSetupAgain:
            PrimaryButton(title: "승인 다시 받기", systemImage: "checkmark.shield", prominent: true) {
                Task { await runtime.reapprove() }
            }
        case .reopenApp, .reconnectGlasses, .chargeGlasses, .recheck, .retryGateway, .sendTestTurn, .none:
            // Never an agent turn: "다시 확인" is a health check.
            PrimaryButton(title: "다시 확인", systemImage: "arrow.clockwise", prominent: true,
                          isLoading: runtime.isChecking) {
                Task { await runtime.checkNow() }
            }
        }
    }
}

/// Each likely cause, phrased as what to do.
private struct CauseText: View {
    let cause: RepairCause

    var body: some View {
        switch cause {
        case .glassesOffOrInCase: Text("안경을 케이스에서 꺼내 펼쳐 주세요")
        case .glassesOutOfRange: Text("안경을 iPhone 가까이 두세요")
        case .glassesBatteryLow: Text("안경을 충전해 주세요")
        case .glassesFirmwareOld: Text("Meta AI 앱에서 안경을 업데이트해 주세요")
        case .metaAppNotRegistered: Text("Meta AI 앱에서 Agent Wear Link를 다시 허용해 주세요")
        case .microphoneNotAllowed: Text("Meta AI 앱에서 안경 마이크를 허용해 주세요")
        case .tailscaleOff: Text("이 iPhone의 Tailscale을 켜 주세요")
        case .hostAsleep: Text("게이트웨이 컴퓨터가 켜져 있고 잠자기 상태가 아닌지 확인해 주세요")
        case .weakInternet: Text("Wi‑Fi나 셀룰러 연결을 확인해 주세요")
        case .gatewayStopped: Text("컴퓨터에서 OpenClaw 게이트웨이를 다시 시작해 주세요")
        case .approvalPending: Text("게이트웨이 컴퓨터에서 이 기기를 승인해 주세요")
        case .approvalRevoked: Text("위 버튼으로 승인을 다시 요청해 주세요")
        case .agentBusy: Text("잠시 후 다시 불러 보세요")
        }
    }
}
