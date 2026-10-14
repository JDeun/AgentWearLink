import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var runtime: CompanionRuntime
    @State private var phrasesText = ""
    @State private var confirmReapprove = false
    @State private var confirmReset = false
    @State private var versionTaps = 0
    @State private var showDiagnostics = false
    @State private var showFullFingerprint = false

    var body: some View {
        Form {
            Section {
                SettingToggle(
                    isOn: binding(\.listenEnabled),
                    title: "안경 호출 받기",
                    detail: "안경으로 부르면 에이전트에게 연결",
                    warning: "안경으로 불러도 응답하지 않습니다"
                )
                SettingToggle(
                    isOn: binding(\.telegramEnabled),
                    title: "텔레그램에 기록",
                    detail: "에이전트의 답을 텔레그램 대화에도 남깁니다",
                    warning: "끄면 대화가 어디에도 남지 않습니다"
                )
                if runtime.settings.telegramEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("텔레그램 채팅 ID")
                            .font(.subheadline.weight(.semibold))
                        // Numbers-first keyboard: group chat ids start with "-".
                        TextField(text: binding(\.telegramChatID), prompt: Text(verbatim: "123456789")) {
                            Text("텔레그램 채팅 ID")
                        }
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Text("에이전트 답을 받을 텔레그램 채팅의 숫자 ID")
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                        if !runtime.settings.telegramChatID.isEmpty,
                           !CompanionTurnOptions.isTelegramChatID(runtime.settings.telegramChatID) {
                            Text("숫자로 된 채팅 ID를 입력해 주세요")
                                .font(.caption)
                                .foregroundStyle(Theme.problem)
                        }
                    }
                }
                SettingToggle(
                    isOn: binding(\.voiceStyle),
                    title: "짧게 말로 답하기",
                    detail: "두세 문장, 긴 답은 텔레그램에서 전체 보기",
                    warning: "긴 답이 안경에서 끝까지 읽힙니다"
                )
            } header: {
                Text("대화")
            }

            Section {
                TextField(text: $phrasesText, axis: .vertical) { Text("호출 문구") }
                    .lineLimit(2...5)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(savePhrases)
                HStack {
                    Button("저장", action: savePhrases)
                        .disabled(WakePhrases.parse(phrasesText) == runtime.settings.effectiveWakePhrases)
                    Spacer()
                    Button("기본값으로") {
                        runtime.settings.wakePhrases = []
                        phrasesText = runtime.settings.effectiveWakePhrases.joined(separator: ", ")
                    }
                }
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
            } header: {
                Text("호출 문구")
            } footer: {
                Text("쉼표로 구분합니다. 이 문구로 시작하는 말만 에이전트에게 보냅니다. 안경을 두 번 톡톡 치면 이름 없이 바로 말할 수 있어요.")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("게이트웨이 이름")
                        .font(.subheadline.weight(.semibold))
                    TextField(
                        text: binding(\.gatewayName),
                        prompt: Text(verbatim: defaultGatewayName)
                    ) {
                        Text("게이트웨이 이름")
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minHeight: 44)
                }
                DisclosureGroup(isExpanded: $showFullFingerprint) {
                    Text(verbatim: DeviceFingerprint.grouped(runtime.deviceID))
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.secondary)
                        .textSelection(.enabled)
                } label: {
                    LabeledContent {
                        Text(verbatim: DeviceFingerprint.short(runtime.deviceID))
                            .font(.body.monospaced().weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    } label: {
                        Text("이 기기 지문")
                    }
                }
                .frame(minHeight: 44)
                if !runtime.settings.agentName.isEmpty {
                    LabeledContent {
                        Text(verbatim: runtime.settings.agentName)
                    } label: {
                        Text("에이전트")
                    }
                }
            } header: {
                Text("기기")
            }

            Section {
                Button {
                    confirmReapprove = true
                } label: {
                    Text("승인만 다시 받기").frame(minHeight: 44)
                }
                Button(role: .destructive) {
                    confirmReset = true
                } label: {
                    Text("모두 지우고 처음부터 설정").frame(minHeight: 44)
                }
            }

            Section {
                if showDiagnostics {
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Text("진단 로그 (개발자용)")
                    }
                }
            } footer: {
                Text(verbatim: "Agent Wear Link \(Self.version)")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        versionTaps += 1
                        if versionTaps >= 5 { showDiagnostics = true }
                    }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(Text("설정"))
        .onAppear {
            phrasesText = runtime.settings.effectiveWakePhrases.joined(separator: ", ")
        }
        .confirmationDialog(Text("승인만 다시 받기"), isPresented: $confirmReapprove, titleVisibility: .visible) {
            Button("승인 다시 받기") { Task { await runtime.reapprove() } }
        } message: {
            Text("이 기기의 저장된 승인을 지우고 게이트웨이 연결 단계로 돌아갑니다. 다른 설정은 그대로입니다.")
        }
        .confirmationDialog(Text("모두 지우고 처음부터"), isPresented: $confirmReset, titleVisibility: .visible) {
            Button("모두 지우기", role: .destructive) { Task { await runtime.resetEverything() } }
        } message: {
            Text("승인, 기기 지문, 모든 설정을 지우고 처음 설정부터 다시 시작합니다.")
        }
    }

    /// Placeholder: the name derived from the paired host, else "게이트웨이".
    private var defaultGatewayName: String {
        let derived = GatewayAddress.defaultName(forGatewayURL: runtime.settings.gatewayURL)
        return derived.isEmpty ? String(localized: "게이트웨이") : derived
    }

    private func savePhrases() {
        let parsed = WakePhrases.parse(phrasesText)
        let defaults = WakePhrases.defaults(forAgentName: runtime.settings.agentName)
        runtime.settings.wakePhrases = parsed == defaults ? [] : parsed
        phrasesText = runtime.settings.effectiveWakePhrases.joined(separator: ", ")
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<CompanionSettings, Value>) -> Binding<Value> {
        Binding(
            get: { runtime.settings[keyPath: keyPath] },
            set: { runtime.settings[keyPath: keyPath] = $0 }
        )
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

private struct SettingToggle: View {
    @Binding var isOn: Bool
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let warning: LocalizedStringKey

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(Theme.secondary)
                if !isOn {
                    Label {
                        Text(warning)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.footnote)
                    .foregroundStyle(Theme.problem)
                }
            }
            .padding(.vertical, 4)
        }
        .tint(Theme.accent)
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject private var runtime: CompanionRuntime
    @State private var copied = false

    var body: some View {
        List {
            Section {
                Button {
                    runtime.copyDiagnostics()
                    copied = true
                } label: {
                    Label(copied ? "복사됨" : "로그 복사", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(minHeight: 44)
                }
            } footer: {
                Text("연결 상태 기록만 담깁니다. 토큰과 말한 내용은 기록하지 않습니다.")
            }
            Section {
                ForEach(runtime.log.entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.date, format: .dateTime.hour().minute().second())
                            .font(.caption2.monospaced())
                            .foregroundStyle(Theme.tertiary)
                        Text(verbatim: entry.message)
                            .font(.footnote.monospaced())
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(Text("진단 로그"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
