import AgentWearLinkCore
import SwiftUI

enum Theme {
    static let background = Color(hex: 0x0D1015)
    static let card = Color(hex: 0x151A22)
    static let raised = Color(hex: 0x1A1F28)
    static let control = Color(hex: 0x1C2633)
    static let text = Color(hex: 0xECEFF4)
    static let secondary = Color(hex: 0x9AA3B2)
    static let tertiary = Color(hex: 0x6B7383)
    static let accent = Color("AccentColor")
    static let ok = Color(hex: 0x5FD39A)
    static let okBackground = Color(hex: 0x12241B)
    static let okInner = Color(hex: 0x183326)
    static let problem = Color(hex: 0xF2B46A)
    static let problemBackground = Color(hex: 0x2A1E10)
    static let problemInner = Color(hex: 0x33250F)
    static let waitingBackground = Color(hex: 0x10273B)
    static let waitingInner = Color(hex: 0x14324B)
    static let danger = Color(hex: 0xFF8A8A)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

enum RelativeTime {
    /// "12초 전" / "12 sec. ago", localized by the system.
    static func string(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        if now.timeIntervalSince(date) < 5 { formatter.dateTimeStyle = .named }
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }
}

struct Card<Content: View>: View {
    var background: Color = Theme.card
    var radius: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct PrimaryButton: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: LocalizedStringKey
    var systemImage: String?
    var prominent = false
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView().tint(prominent ? Theme.background : Theme.accent)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }

    // Disabled buttons keep readable contrast instead of a washed-out accent.
    private var foreground: Color {
        guard isEnabled else { return Theme.tertiary }
        return prominent ? Theme.background : Theme.accent
    }

    private var background: Color {
        guard isEnabled else { return Theme.raised }
        return prominent ? Theme.accent : Theme.control
    }
}

/// The five-hop chain with a status dot per hop and the time it was checked.
struct ChainListView: View {
    let rows: [HomeViewState.Row]
    let signals: ConnectionSignals
    let agentName: String
    let gatewayName: String

    var body: some View {
        Card {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    ChainRowView(
                        row: row,
                        isFirst: index == 0,
                        isLast: index == rows.count - 1,
                        signals: signals,
                        agentName: agentName,
                        gatewayName: gatewayName
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }
}

struct ChainRowView: View {
    let row: HomeViewState.Row
    let isFirst: Bool
    let isLast: Bool
    let signals: ConnectionSignals
    let agentName: String
    let gatewayName: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(spacing: 0) {
                Rectangle().fill(isFirst ? .clear : Theme.raised).frame(width: 2)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 32, height: 32)
                    .background(Color(hex: 0x1C222C), in: Circle())
                Rectangle().fill(isLast ? .clear : Theme.raised).frame(width: 2)
            }
            .frame(width: 32)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                title.font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                detail.font(.footnote).foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)

            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    stateLabel.font(.footnote).foregroundStyle(color)
                }
                if let checkedAt = row.checkedAt, row.state != .notCheckable {
                    Text(RelativeTime.string(checkedAt))
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiary)
                }
            }
        }
        .frame(minHeight: 56)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch row.id {
        case .glasses: "eyeglasses"
        case .phone: "iphone"
        case .network: "network"
        case .gateway: "desktopcomputer"
        case .agent: "person.wave.2"
        }
    }

    private var color: Color {
        switch row.state {
        case .ok: Theme.ok
        case .problem: Theme.problem
        case .waiting: Theme.accent
        case .checking, .notCheckable: Theme.tertiary
        }
    }

    @ViewBuilder private var title: some View {
        switch row.id {
        case .glasses: Text("메타 안경")
        case .phone: Text("이 iPhone")
        case .network: Text("네트워크")
        case .gateway: Text(verbatim: gatewayName)
        case .agent:
            if agentName.isEmpty { Text("에이전트") } else { Text(verbatim: agentName) }
        }
    }

    @ViewBuilder private var stateLabel: some View {
        switch row.state {
        case .ok: row.id == .agent ? Text("응답함") : Text("연결됨")
        case .problem: Text("끊김")
        case .waiting: Text("대기 중")
        case .checking: Text("확인 중")
        case .notCheckable: Text(verbatim: "—")
        }
    }

    @ViewBuilder private var detail: some View {
        switch row.state {
        case .notCheckable: Text("확인할 수 없음")
        case let .problem(reason): ProblemText(reason: reason)
        case .waiting: Text("쓰면 자동으로 연결돼요")
        case .checking:
            switch row.id {
            case .agent: Text("아직 대화 없음")
            case .phone:
                if signals.listening && !signals.speechReady {
                    Text("음성 인식이 시작되지 않음")
                } else {
                    Text("안경과 연결하는 중")
                }
            default: Text("확인 중")
            }
        case .ok:
            switch row.id {
            case .glasses:
                if let battery = signals.glassesBattery {
                    Text("연결됨 · 배터리 \(battery)%")
                } else {
                    Text("연결됨")
                }
            case .phone:
                signals.listening && signals.speechReady ? Text("듣는 중") : Text("앱 실행 중")
            case .network:
                Text("Tailscale로 게이트웨이 응답")
            case .gateway:
                Text("OpenClaw 게이트웨이 · 이 기기 승인됨")
            case .agent:
                if let last = signals.lastReplyAt {
                    Text("마지막 응답 \(RelativeTime.string(last))")
                } else {
                    Text("아직 대화 없음")
                }
            }
        }
    }
}

/// One-line description of a broken hop.
struct ProblemText: View {
    let reason: AWLChainProblemReason

    var body: some View {
        switch reason {
        case .glassesNotConnected: Text("안경이 연결되지 않음")
        case .glassesBatteryCritical: Text("안경 배터리가 거의 없음")
        case .glassesUpdateRequired: Text("안경 소프트웨어 업데이트 필요")
        case .metaRegistrationMissing: Text("Meta AI 앱 등록 필요")
        case .microphoneDenied: Text("안경 마이크 권한 없음")
        case .appNotRunning: Text("앱이 실행 중이 아님")
        case .networkUnreachable: Text("게이트웨이까지 닿지 않음")
        case .gatewayUnreachable: Text("게이트웨이가 응답하지 않음")
        case .pairingPending: Text("게이트웨이에서 승인 대기 중")
        case .pairingRevoked: Text("이 기기 승인이 필요함")
        case .agentNotResponding: Text("에이전트가 응답하지 않음")
        }
    }
}

/// Headline for the Repair screen and the problem banner.
struct ProblemHeadline: View {
    let link: AWLChainLinkID
    let gatewayName: String

    var body: some View {
        switch link {
        case .glasses: Text("안경 연결에 문제가 있어요")
        case .phone: Text("이 iPhone 설정이 필요해요")
        case .network: Text("\(gatewayName)에 닿지 않아요")
        case .gateway: Text("\(gatewayName)에 문제가 있어요")
        case .agent: Text("에이전트가 답하지 않아요")
        }
    }
}

/// A vertical ScrollView with a bottom anchor. DEBUG screenshot fixtures can
/// ask it to render its lower part (`-AWLPreviewScroll bottom`).
struct AnchoredScrollView<Content: View>: View {
    var scrollsToBottom = false
    @ViewBuilder var content: Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content
                Color.clear.frame(height: 1).id(Self.bottomID)
            }
            .task {
                #if DEBUG
                guard scrollsToBottom, CompanionPreviewFixture.scrollsToBottom else { return }
                try? await Task.sleep(for: .milliseconds(600))
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
                #endif
            }
        }
    }

    static var bottomID: String { "awl-bottom" }
}
