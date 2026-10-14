import AgentWearLinkCore
import SwiftUI
import UIKit

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

/// Opens other apps the user needs during setup or repair.
enum ExternalApps {
    /// Tailscale's App Store page, used when the app is not installed or
    /// does not answer its URL scheme.
    static let tailscaleAppStore = URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!

    @MainActor
    static func openTailscale() {
        guard let scheme = URL(string: "tailscale://") else { return }
        UIApplication.shared.open(scheme) { opened in
            if !opened { UIApplication.shared.open(tailscaleAppStore) }
        }
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
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.body.weight(.semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
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

/// The five-hop chain. One "checked" time lives in the hero, not per row.
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
    @Environment(\.dynamicTypeSize) private var typeSize
    let row: HomeViewState.Row
    let isFirst: Bool
    let isLast: Bool
    let signals: ConnectionSignals
    let agentName: String
    let gatewayName: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if !typeSize.isAccessibilitySize {
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
            }

            if typeSize.isAccessibilitySize {
                // Stacked: title, detail, then status, so nothing breaks mid-word.
                VStack(alignment: .leading, spacing: 4) {
                    title.font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                    detail.font(.footnote).foregroundStyle(Theme.secondary)
                    status
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    title.font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                    detail.font(.footnote).foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                status.fixedSize()
            }
        }
        .frame(minHeight: 56)
        .accessibilityElement(children: .combine)
    }

    private var status: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            StatusLabelText(label: HomeViewState.statusLabel(for: row))
                .font(.footnote.weight(.medium))
                .foregroundStyle(color)
        }
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
        case .problem, .notListening: Theme.problem
        case .waiting, .resting: Theme.accent
        case .checking, .notCheckable: Theme.tertiary
        }
    }

    @ViewBuilder private var title: some View {
        switch row.id {
        case .glasses: Text("Meta 안경")
        case .phone: Text("이 iPhone")
        case .network: Text("네트워크")
        case .gateway: Text(verbatim: gatewayName)
        case .agent:
            if agentName.isEmpty { Text("에이전트") } else { Text(verbatim: agentName) }
        }
    }

    @ViewBuilder private var detail: some View {
        switch row.state {
        case .notCheckable: Text("앞 단계가 끊겨 확인할 수 없어요")
        case let .problem(reason): ProblemText(reason: reason)
        case .waiting: Text("쓰면 자동으로 연결돼요")
        case .notListening: Text("음성 인식이 멈춰 있어요")
        case .resting:
            signals.speechPause == .pauseFolded
                ? Text("접혀 있어요 · 펼쳐 쓰면 다시 들어요") : Text("벗어 두었어요 · 쓰면 다시 들어요")
        case .checking:
            switch row.id {
            case .agent: Text("아직 대화가 없어요")
            case .phone: Text("안경과 연결하는 중")
            default: Text("확인하는 중")
            }
        case .ok:
            switch row.id {
            case .glasses: Text("착용 중")
            case .phone:
                signals.listening && signals.speechReady ? Text("듣는 중") : Text("앱 실행 중")
            case .network: Text("Tailscale로 연결됨")
            case .gateway: Text("에이전트가 있는 컴퓨터 · 승인됨")
            case .agent:
                if let last = signals.lastReplyAt {
                    Text("마지막 응답 \(RelativeTime.string(last))")
                } else {
                    Text("아직 대화가 없어요")
                }
            }
        }
    }
}

struct StatusLabelText: View {
    let label: HomeViewState.StatusLabel

    var body: some View {
        switch label {
        case .connected: Text("연결됨")
        case .answered: Text("응답함")
        case .waiting: Text("대기 중")
        case .checking: Text("확인 중")
        case .notCheckable: Text(verbatim: "—")
        case .disconnected: Text("연결 끊김")
        case .needsApproval: Text("승인 필요")
        case .needsCharging: Text("충전 필요")
        case .updateNeeded: Text("업데이트 필요")
        case .notResponding: Text("응답 없음")
        case .needsPermission: Text("권한 필요")
        case .needsRegistration: Text("허용 필요")
        case .notListening: Text("듣지 않음")
        }
    }
}

/// Short row detail for a broken hop.
struct ProblemText: View {
    let reason: AWLChainProblemReason

    var body: some View {
        switch reason {
        case .glassesNotConnected: Text("안경이 연결되지 않았어요")
        case .glassesBatteryCritical: Text("배터리가 거의 없어요")
        case .glassesUpdateRequired: Text("소프트웨어 업데이트가 필요해요")
        case .metaRegistrationMissing: Text("Meta AI 앱에서 허용이 필요해요")
        case .microphoneDenied: Text("안경 마이크 권한이 없어요")
        case .appNotRunning: Text("앱이 실행 중이 아니에요")
        case .networkUnreachable: Text("게이트웨이 컴퓨터에 닿지 않아요")
        case .gatewayUnreachable: Text("게이트웨이가 응답하지 않아요")
        case .pairingPending: Text("이 기기 승인을 기다리는 중")
        case .pairingRevoked: Text("이 기기 승인이 필요해요")
        case .agentNotResponding: Text("답이 오지 않아요")
        }
    }
}

/// Hero headline: names the thing that is wrong.
struct ProblemHeadline: View {
    let reason: AWLChainProblemReason
    let gatewayName: String
    let agentName: String

    var body: some View {
        switch reason {
        case .glassesNotConnected: Text("Meta 안경이 연결되지 않았어요")
        case .glassesBatteryCritical: Text("Meta 안경 배터리가 거의 없어요")
        case .glassesUpdateRequired: Text("Meta 안경 업데이트가 필요해요")
        case .metaRegistrationMissing: Text("Meta AI 앱에서 허용이 필요해요")
        case .microphoneDenied: Text("안경 마이크 권한이 필요해요")
        case .appNotRunning: Text("앱을 다시 열어 주세요")
        case .networkUnreachable: Text("\(gatewayName)에 닿지 않아요")
        case .gatewayUnreachable: Text("\(gatewayName)에서 응답이 없어요")
        case .pairingPending: Text("\(gatewayName)에서 승인이 필요해요")
        case .pairingRevoked: Text("\(gatewayName)에서 다시 승인받아야 해요")
        case .agentNotResponding: Text("\(agentName)에게서 답이 없어요")
        }
    }
}

/// Hero subtitle: the likely reason, not a repeat of the headline.
struct ProblemReasonText: View {
    let reason: AWLChainProblemReason

    var body: some View {
        switch reason {
        case .glassesNotConnected: Text("안경을 펼쳐 쓰면 자동으로 연결돼요")
        case .glassesBatteryCritical: Text("충전기에 연결해 주세요")
        case .glassesUpdateRequired: Text("Meta AI 앱에서 업데이트해 주세요")
        case .metaRegistrationMissing: Text("Meta AI 앱에서 Agent Wear Link를 허용해 주세요")
        case .microphoneDenied: Text("Meta AI 앱에서 마이크를 허용해 주세요")
        case .appNotRunning: Text("앱이 종료돼 연결이 끊겼어요")
        case .networkUnreachable: Text("Tailscale이 꺼져 있을 수 있어요")
        case .gatewayUnreachable: Text("OpenClaw가 멈췄거나 컴퓨터가 잠들었을 수 있어요")
        case .pairingPending: Text("컴퓨터에서 이 기기를 승인해 주세요")
        case .pairingRevoked: Text("저장된 승인이 더 이상 유효하지 않아요")
        case .agentNotResponding: Text("바쁘거나 응답이 늦을 수 있어요")
        }
    }
}

/// A command line with a copy button.
struct CommandRow: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(verbatim: command)
                .font(.footnote.monospaced())
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                UIPasteboard.general.string = command
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text("명령어 복사"))
        }
        .padding(.leading, 12)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Exactly what to do on the Gateway computer to approve this iPhone.
struct ApprovalInstructions: View {
    let fingerprint: String
    let requestID: String?

    private var approveCommand: String {
        "openclaw devices approve \(requestID ?? "<requestId>")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("게이트웨이 컴퓨터의 터미널에서")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.text)
            Text("1. 요청 목록을 열어요")
                .font(.footnote)
                .foregroundStyle(Theme.secondary)
            CommandRow(command: "openclaw devices list")
            Text("2. 지문이 \(Text(verbatim: fingerprint).font(.footnote.monospaced().weight(.bold)).foregroundColor(Theme.accent))인 요청을 승인해요")
                .font(.footnote)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            CommandRow(command: approveCommand)
            Label {
                Text("이 화면은 승인되면 자동으로 넘어가요")
            } icon: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .font(.footnote)
            .foregroundStyle(Theme.tertiary)
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
