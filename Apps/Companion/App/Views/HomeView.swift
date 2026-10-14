import AgentWearLinkCore
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var runtime: CompanionRuntime
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showSettings = false
    @State private var repairProblem: AWLChainProblem?

    var body: some View {
        let state = runtime.homeState
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            AnchoredScrollView(scrollsToBottom: !showSettings && repairProblem == nil) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(verbatim: "Agent Wear Link")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    StatusBanner(
                        state: state,
                        wakePhrase: runtime.settings.effectiveWakePhrases.first ?? "",
                        lastCheckAt: runtime.lastCheckAt,
                        speechPause: runtime.signals.speechPause,
                        gatewayName: runtime.gatewayLabel,
                        agentName: runtime.agentLabel,
                        onRepair: { repairProblem = $0 },
                        onRestart: { runtime.restartListening() },
                        onResume: { runtime.settings.listenEnabled = true }
                    )
                    if runtime.signals.replyNotSpoken {
                        Card(background: Theme.raised) {
                            Label {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("안경으로 들을 수 없어 답을 소리 내지 않았어요")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.text)
                                    if state.showsTelegramLink {
                                        Text("답변은 텔레그램에서 확인하세요")
                                    } else {
                                        Text("iPhone 스피커로는 읽지 않아요. 안경이 연결되면 다음 답부터 들려요")
                                    }
                                }
                                .font(.footnote)
                                .foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "speaker.slash").foregroundStyle(Theme.problem)
                            }
                            .padding(14)
                        }
                    }
                    if case let .problem(problem) = state.banner,
                       problem.reason == .pairingPending || problem.reason == .pairingRevoked {
                        approvalCard(problem.reason)
                    }
                    ChainListView(
                        rows: state.rows,
                        signals: runtime.signals,
                        agentName: runtime.settings.agentName,
                        gatewayName: runtime.gatewayLabel
                    )
                    tiles
                    if state.showsTelegramLink {
                        Label("대화 기록은 텔레그램에서 볼 수 있어요", systemImage: "paperplane")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    VStack(spacing: 10) {
                        PrimaryButton(
                            title: "지금 다시 확인",
                            systemImage: "arrow.clockwise",
                            isLoading: runtime.isChecking
                        ) {
                            Task { await runtime.checkNow() }
                        }
                        Text("에이전트에게 묻지 않는 점검이라 대화 기록에 남지 않아요")
                            .font(.caption)
                            .foregroundStyle(Theme.tertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                        if runtime.settings.listenEnabled {
                            Button {
                                runtime.settings.listenEnabled = false
                            } label: {
                                Label("듣기 일시정지", systemImage: "pause.circle")
                                    .font(.subheadline)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .foregroundStyle(Theme.secondary)
                        }
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
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
            if CompanionPreviewFixture.opensRepair { repairProblem = runtime.signals.chain.firstProblem }
            #endif
        }
    }

    private func approvalCard(_ reason: AWLChainProblemReason) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                if reason == .pairingRevoked {
                    Text("‘승인 다시 받기’를 누르면 게이트웨이 컴퓨터에 새 승인 요청이 가요.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    PrimaryButton(title: "승인 다시 받기", systemImage: "checkmark.shield", prominent: true) {
                        Task { await runtime.reapprove() }
                    }
                } else {
                    ApprovalInstructions(
                        fingerprint: DeviceFingerprint.short(runtime.deviceID),
                        requestID: runtime.pendingRequestID
                    )
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder private var tiles: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        layout {
            Tile(title: "마지막 대화") {
                if let last = runtime.signals.lastReplyAt {
                    Text(RelativeTime.string(last))
                } else {
                    Text("아직 없어요")
                }
            } footnote: {
                EmptyView()
            }
            Tile(title: "안경 배터리") {
                if let battery = runtime.signals.glassesBattery {
                    Text(verbatim: "\(battery)%").monospacedDigit()
                } else {
                    Text(verbatim: "—")
                }
            } footnote: {
                if runtime.signals.glassesBattery == nil {
                    Text("안경을 쓰면 보여요")
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
    @Environment(\.dynamicTypeSize) private var typeSize
    let state: HomeViewState
    let wakePhrase: String
    let lastCheckAt: Date?
    var speechPause: SpeechPowerPolicy.Decision = .listen
    let gatewayName: String
    let agentName: String
    let onRepair: (AWLChainProblem) -> Void
    let onRestart: () -> Void
    let onResume: () -> Void

    var body: some View {
        Card(background: palette.background, radius: 24) {
            VStack(alignment: .leading, spacing: 12) {
                let layout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                    : AnyLayout(HStackLayout(spacing: 14))
                layout {
                    Image(systemName: palette.icon)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(palette.tint)
                        .frame(width: 44, height: 44)
                        .background(palette.inner, in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        headline.font(.title3.weight(.bold)).foregroundStyle(Theme.text)
                        subtitle.font(.footnote).foregroundStyle(Theme.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    if problem != nil, !typeSize.isAccessibilitySize {
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").foregroundStyle(palette.tint)
                    }
                }
                if state.showsCallHint, !wakePhrase.isEmpty {
                    Text("안경에서 “\(wakePhrase), …” 하고 말하세요")
                        .font(.subheadline)
                        .foregroundStyle(Theme.text.opacity(0.9))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(palette.inner, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                if state.banner == .notListening {
                    PrimaryButton(title: "다시 시작", systemImage: "arrow.clockwise", prominent: true, action: onRestart)
                }
                if state.banner == .listeningOff {
                    PrimaryButton(title: "다시 듣기", systemImage: "play.fill", prominent: true, action: onResume)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let problem { onRepair(problem) }
        }
        .accessibilityAddTraits(problem != nil ? .isButton : [])
    }

    private var problem: AWLChainProblem? {
        if case let .problem(problem) = state.banner { return problem }
        return nil
    }

    private var palette: (background: Color, inner: Color, tint: Color, icon: String) {
        switch state.banner {
        case .allConnected: (Theme.okBackground, Theme.okInner, Theme.ok, "checkmark")
        case .waitingForGlasses: (Theme.waitingBackground, Theme.waitingInner, Theme.accent, "eyeglasses")
        case .listeningOff: (Theme.card, Theme.raised, Theme.secondary, "pause.fill")
        case .problem, .notListening: (Theme.problemBackground, Theme.problemInner, Theme.problem, "exclamationmark")
        case .thermalShed: (Theme.problemBackground, Theme.problemInner, Theme.problem, "thermometer.high")
        case .checking: (Theme.card, Theme.raised, Theme.accent, "ellipsis")
        }
    }

    @ViewBuilder private var headline: some View {
        switch state.banner {
        case .allConnected: Text("모두 연결됨")
        case .waitingForGlasses: Text("안경을 기다리고 있어요")
        case .listeningOff: Text("듣기를 멈췄어요")
        case .notListening: Text("지금 듣고 있지 않아요")
        case .thermalShed: Text("안경이 뜨거워 잠시 듣기를 멈췄어요")
        case let .problem(problem):
            ProblemHeadline(reason: problem.reason, gatewayName: gatewayName, agentName: agentName)
        case .checking: Text("확인하는 중")
        }
    }

    @ViewBuilder private var subtitle: some View {
        switch state.banner {
        case let .allConnected(checkedAt):
            if let date = checkedAt ?? lastCheckAt {
                Text("\(RelativeTime.string(date)) 확인")
            } else {
                Text("방금 확인")
            }
        case .waitingForGlasses:
            switch speechPause {
            case .pauseNotWorn: Text("배터리를 아끼려고 듣기를 쉬어요. 다시 쓰면 바로 들어요")
            case .pauseFolded: Text("배터리를 아끼려고 듣기를 쉬어요. 펼쳐 쓰면 바로 들어요")
            default: Text("안경을 쓰면 자동으로 연결돼요")
            }
        case .thermalShed: Text("식으면 자동으로 다시 들어요")
        case .listeningOff: Text("다시 듣기를 누르면 이어서 들어요")
        case .notListening: Text("안경 음성 인식이 시작되지 않았어요")
        case let .problem(problem): ProblemReasonText(reason: problem.reason)
        case .checking: Text("연결 상태를 확인하고 있어요")
        }
    }
}
