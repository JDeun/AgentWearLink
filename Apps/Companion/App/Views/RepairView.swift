import AgentWearLinkCore
import SwiftUI
import UIKit

/// The first broken hop, its likely causes and exactly one action.
struct RepairView: View {
    @EnvironmentObject private var runtime: CompanionRuntime
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let problem: AWLChainProblem

    var body: some View {
        let guide = RepairGuide(problem: problem)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card(background: Theme.problemBackground, radius: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        ProblemHeadline(link: problem.link, gatewayName: runtime.gatewayLabel)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Theme.text)
                        ProblemText(reason: problem.reason)
                            .font(.subheadline)
                            .foregroundStyle(Color(hex: 0xD9C3A5))
                        if let checked = runtime.lastCheckAt {
                            Text("\(RelativeTime.string(checked)) 확인")
                                .font(.footnote)
                                .foregroundStyle(Color(hex: 0xD9C3A5).opacity(0.8))
                        }
                    }
                    .padding(20)
                }

                if !guide.causes.isEmpty {
                    Text("이런 경우가 많아요")
                        .font(.headline)
                        .foregroundStyle(Theme.text)
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(guide.causes.enumerated()), id: \.element) { index, cause in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(verbatim: "\(index + 1)")
                                        .font(.footnote.weight(.bold))
                                        .foregroundStyle(Theme.problem)
                                        .frame(width: 22, height: 22)
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
                        Label {
                            Text("Tailscale 앱 설정에서 VPN On Demand를 켜 두면 이 문제가 거의 생기지 않아요. 이 앱은 Tailscale 상태를 직접 확인하거나 켤 수 없어요.")
                                .font(.footnote)
                                .foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "lightbulb").foregroundStyle(Theme.accent)
                        }
                        .padding(14)
                    }
                }

                actionButton(guide.action)
                    .padding(.top, 4)

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
        .navigationTitle(Text("연결 문제 복구"))
        .navigationBarTitleDisplayMode(.inline)
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
            PrimaryButton(title: "승인 후 다시 확인", systemImage: "arrow.clockwise", prominent: true,
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

private struct CauseText: View {
    let cause: RepairCause

    var body: some View {
        switch cause {
        case .glassesOffOrInCase: Text("안경이 꺼져 있거나 케이스 안에 있음")
        case .glassesOutOfRange: Text("안경이 iPhone에서 멀리 떨어져 있음")
        case .glassesBatteryLow: Text("안경 배터리가 거의 없음 — 충전해 주세요")
        case .glassesFirmwareOld: Text("Meta AI 앱에서 안경 업데이트가 필요함")
        case .metaAppNotRegistered: Text("Meta AI 앱에서 이 앱 연결이 해제됨")
        case .microphoneNotAllowed: Text("Meta AI 앱에서 안경 마이크를 허용하지 않음")
        case .tailscaleOff: Text("이 iPhone의 Tailscale이 꺼짐 — Tailscale 앱에서 켜 주세요")
        case .hostAsleep: Text("게이트웨이 컴퓨터가 꺼졌거나 잠듦")
        case .weakInternet: Text("지금 인터넷 연결이 약함")
        case .gatewayStopped: Text("OpenClaw 게이트웨이가 멈춤")
        case .approvalPending: Text("게이트웨이에서 이 기기 승인을 아직 하지 않음")
        case .approvalRevoked: Text("게이트웨이에서 이 기기 승인이 취소됨")
        case .agentBusy: Text("에이전트가 다른 작업 중이거나 응답이 늦음")
        }
    }
}
