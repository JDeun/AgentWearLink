import AgentWearLinkCore
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var runtime: CompanionRuntime
    @State private var showSettings = false
    @State private var repairProblem: AWLChainProblem?

    var body: some View {
        let state = runtime.homeState
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            ScrollView {
                VStack(spacing: 16) {
                    StatusBanner(
                        banner: state.banner,
                        wakePhrase: runtime.settings.effectiveWakePhrases.first ?? "",
                        lastCheckAt: runtime.lastCheckAt,
                        gatewayName: runtime.gatewayLabel,
                        onRepair: { repairProblem = $0 }
                    )
                    ChainListView(
                        rows: state.rows,
                        signals: runtime.signals,
                        agentName: runtime.settings.agentName,
                        gatewayName: runtime.gatewayLabel
                    )
                    tiles
                    if state.showsTelegramLink {
                        Label("대화 기록은 텔레그램에서", systemImage: "paperplane")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    VStack(spacing: 6) {
                        PrimaryButton(
                            title: "지금 다시 확인",
                            systemImage: "arrow.clockwise",
                            isLoading: runtime.isChecking
                        ) {
                            Task { await runtime.checkNow() }
                        }
                        Text("에이전트에게 묻지 않는 점검이라 대화 기록에 남지 않습니다")
                            .font(.caption)
                            .foregroundStyle(Theme.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Agent Wear Link")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text("설정"))
            }
        }
        .navigationDestination(isPresented: $showSettings) { SettingsView() }
        .navigationDestination(item: $repairProblem) { RepairView(problem: $0) }
        .refreshable { await runtime.checkNow() }
        .onAppear {
            #if DEBUG
            if CompanionPreviewFixture.opensSettings { showSettings = true }
            #endif
        }
    }

    private var tiles: some View {
        HStack(spacing: 10) {
            Tile(title: "마지막 대화") {
                if let last = runtime.signals.lastReplyAt {
                    Text(RelativeTime.string(last))
                } else {
                    Text("아직 없음")
                }
            } footnote: {
                if let latency = runtime.signals.lastReplyLatency {
                    Text("말 끝 → 답 시작 \(latency, format: .number.precision(.fractionLength(1)))초")
                } else {
                    Text("말 끝 → 답 시작 —")
                }
            }
            Tile(title: "안경 배터리") {
                if let battery = runtime.signals.glassesBattery {
                    Text(verbatim: "\(battery)%").monospacedDigit()
                } else {
                    Text(verbatim: "—")
                }
            } footnote: {
                if runtime.signals.glassesBattery == nil {
                    Text("안경을 쓰면 표시")
                } else if runtime.signals.glassesCharging {
                    Text("충전 중")
                } else {
                    Text("충전 안 함")
                }
            }
        }
    }
}

extension AWLChainProblem: @retroactive Identifiable {
    public var id: String { "\(link.rawValue)-\(reason.rawValue)" }
}

extension AWLChainProblem: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(link)
        hasher.combine(reason)
    }
}

private struct Tile<Value: View, Footnote: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var value: Value
    @ViewBuilder var footnote: Footnote

    var body: some View {
        Card(radius: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(Theme.secondary)
                value.font(.headline).foregroundStyle(Theme.text)
                footnote.font(.caption).foregroundStyle(Theme.secondary)
            }
            .padding(14)
        }
        .accessibilityElement(children: .combine)
    }
}

struct StatusBanner: View {
    let banner: HomeViewState.Banner
    let wakePhrase: String
    let lastCheckAt: Date?
    let gatewayName: String
    let onRepair: (AWLChainProblem) -> Void

    var body: some View {
        Card(background: palette.background, radius: 24) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Image(systemName: palette.icon)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(palette.tint)
                        .frame(width: 44, height: 44)
                        .background(palette.inner, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        headline.font(.title3.weight(.bold)).foregroundStyle(Theme.text)
                        subtitle.font(.footnote).foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 0)
                    if case .problem = banner {
                        Image(systemName: "chevron.right").foregroundStyle(palette.tint)
                    }
                }
                if !wakePhrase.isEmpty, !isProblem {
                    Text("안경에서 “\(wakePhrase), …” 하고 말하세요")
                        .font(.subheadline)
                        .foregroundStyle(Theme.text.opacity(0.9))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(palette.inner, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if case let .problem(problem) = banner { onRepair(problem) }
        }
        .accessibilityAddTraits(isProblem ? .isButton : [])
    }

    private var isProblem: Bool {
        if case .problem = banner { return true }
        return false
    }

    private var palette: (background: Color, inner: Color, tint: Color, icon: String) {
        switch banner {
        case .allConnected: (Theme.okBackground, Theme.okInner, Theme.ok, "checkmark")
        case .waitingForGlasses: (Theme.waitingBackground, Theme.waitingInner, Theme.accent, "eyeglasses")
        case .listeningOff: (Theme.card, Theme.raised, Theme.secondary, "pause.fill")
        case .problem: (Theme.problemBackground, Theme.problemInner, Theme.problem, "exclamationmark")
        case .checking: (Theme.card, Theme.raised, Theme.accent, "ellipsis")
        }
    }

    @ViewBuilder private var headline: some View {
        switch banner {
        case .allConnected: Text("모두 연결됨")
        case .waitingForGlasses: Text("안경 대기 중")
        case .listeningOff: Text("안경 호출 꺼짐")
        case let .problem(problem): ProblemHeadline(link: problem.link, gatewayName: gatewayName)
        case .checking: Text("확인 중")
        }
    }

    @ViewBuilder private var subtitle: some View {
        switch banner {
        case let .allConnected(checkedAt):
            if let date = checkedAt ?? lastCheckAt {
                Text("\(RelativeTime.string(date)) 확인")
            } else {
                Text("방금 확인")
            }
        case .waitingForGlasses: Text("쓰면 자동 연결")
        case .listeningOff: Text("설정에서 다시 켤 수 있어요")
        case let .problem(problem): ProblemText(reason: problem.reason)
        case .checking: Text("연결 상태를 확인하고 있어요")
        }
    }
}
