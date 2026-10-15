import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var runtime: CompanionRuntime
    @State private var phrasesText = ""
    @State private var spokenNameDraft = ""
    @State private var gatewayNameDraft = ""
    @State private var confirmReapprove = false
    @State private var confirmReset = false
    @State private var versionTaps = 0
    @State private var showDiagnostics = false
    @State private var showFullFingerprint = false
    @State private var openDiagnostics = false
    /// Edited locally and committed on submit or focus loss: every change
    /// restarts the voice session, so it must not follow each keystroke.
    @State private var chatIDDraft = ""
    @FocusState private var focused: Field?

    private enum Field { case chatID, gatewayName, spokenName }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                conversationSection
                wakePhraseSection
                deviceSection
                actionsSection
                advancedSection
                diagnosticsSection
            }
            .task {
                #if DEBUG
                await applyPreview(proxy)
                #endif
            }
        }
        .navigationDestination(isPresented: $openDiagnostics) { DiagnosticsView() }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(Text("설정"))
        .onChange(of: focused) { old, _ in commit(old) }
        .onDisappear {
            commit(.chatID)
            commit(.gatewayName)
            commit(.spokenName)
        }
        .onAppear {
            chatIDDraft = runtime.settings.telegramChatID
            gatewayNameDraft = runtime.gatewayLabel
            spokenNameDraft = runtime.settings.spokenName
            phrasesText = runtime.settings.effectiveWakePhrases.joined(separator: ", ")
        }
        .alert(Text("승인만 다시 받을까요?"), isPresented: $confirmReapprove) {
            Button("승인 다시 받기") { Task { await runtime.reapprove() } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("저장된 승인을 지우고 게이트웨이 연결 단계로 돌아가요. 게이트웨이 컴퓨터에서 다시 승인할 때까지 안경 호출이 멈춰요.")
        }
        .alert(Text("모두 지우고 처음부터 할까요?"), isPresented: $confirmReset) {
            Button("모두 지우기", role: .destructive) { Task { await runtime.resetEverything() } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("승인, 기기 지문, 모든 설정을 지우고 처음 설정부터 다시 시작해요.")
        }
    }

    // MARK: Sections

    private var conversationSection: some View {
        Section {
            SettingToggle(
                isOn: binding(\.listenEnabled),
                title: "안경으로 듣기",
                detail: "안경으로 부르면 에이전트에게 연결해요",
                warning: "안경으로 불러도 응답하지 않아요"
            )
            SettingToggle(
                isOn: binding(\.telegramEnabled),
                title: "텔레그램에 기록",
                detail: "에이전트의 답을 텔레그램 대화에도 남겨요",
                warning: "끄면 대화가 어디에도 남지 않아요"
            )
            if runtime.settings.telegramEnabled, !runtime.settings.isTelegramDeliveryConfigured {
                Label {
                    Text("고급에서 텔레그램 채팅 ID를 입력해야 기록돼요")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.footnote)
                .foregroundStyle(Theme.problem)
            }
            SettingToggle(
                isOn: binding(\.voiceStyle),
                title: "짧게 말로 답하기",
                detail: "두세 문장으로 답해요. 긴 답은 텔레그램에서 볼 수 있어요",
                warning: "긴 답도 안경에서 끝까지 읽어요"
            )
            SettingToggle(
                isOn: binding(\.followUp),
                title: "이어 말하기",
                detail: "답이 끝나고 8초 안에 말하면 이름 없이 이어서 물어요",
                warning: "매번 이름을 불러야 해요"
            )
            SettingToggle(
                isOn: binding(\.audioCues),
                title: "알림음",
                detail: "요청을 받으면 '띵', 기다리는 동안 '톡톡', 이어 말할 수 있을 때 짧은 소리가 나요",
                warning: "답이 올 때까지 아무 소리도 나지 않아요"
            )
            voicePicker
        } header: {
            Text("대화")
        }
    }

    @ViewBuilder private var voicePicker: some View {
        let options = runtime.voiceOptions
        SettingToggle(
            isOn: binding(\.gatewayVoice),
            title: "게이트웨이 목소리",
            detail: "에이전트가 있는 컴퓨터의 로컬 음성 모델로 읽어요. 느리거나 안 되면 아래 목소리로 바로 바꿔 읽어요",
            warning: "아래 iPhone 목소리로 읽어요"
        )
        Picker(selection: binding(\.voiceIdentifier)) {
            Text("기본 목소리").tag("")
            ForEach(options) { option in
                Text(voiceLabel(option)).tag(option.id)
            }
        } label: {
            Text("목소리")
        }
        Button {
            runtime.previewVoice()
        } label: {
            Label("미리 듣기", systemImage: "play.circle")
        }
        Text("안경을 쓰고 있지 않으면 iPhone 스피커로 들려요. 더 많은 목소리는 iPhone 설정 › 손쉬운 사용 › 읽기 및 말하기 › 음성 › 한국어에서 내려받을 수 있어요.")
            .font(.footnote)
            .foregroundStyle(Theme.secondary)
    }

    private func voiceLabel(_ option: VoiceOption) -> String {
        let gender: String
        switch VoiceCatalog.gender(for: option) {
        case .male: gender = String(localized: "남성")
        case .female: gender = String(localized: "여성")
        case .unspecified: gender = ""
        }
        let quality: String
        switch option.quality {
        case .premium: quality = String(localized: "프리미엄")
        case .enhanced: quality = String(localized: "고품질")
        case .standard: quality = ""
        }
        return ([option.name, gender, quality].filter { !$0.isEmpty }).joined(separator: " · ")
    }

    private var wakePhraseSection: some View {
        Section {
            TextField(text: $phrasesText, axis: .vertical) { Text("호출 이름") }
                .lineLimit(2...5)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(savePhrases)
            let edited = WakePhrases.parse(phrasesText) != runtime.settings.effectiveWakePhrases
            if edited || !runtime.settings.wakePhrases.isEmpty {
                HStack {
                    if edited {
                        Button("저장", action: savePhrases)
                    }
                    Spacer()
                    if !runtime.settings.wakePhrases.isEmpty {
                        Button("기본값으로") {
                            runtime.settings.wakePhrases = []
                            phrasesText = runtime.settings.effectiveWakePhrases.joined(separator: ", ")
                        }
                    }
                }
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
            }
            if WakePhrases.prefersKorean, WakePhrases.needsPronunciation(agentName: runtime.settings.agentName) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("한국어로 부르는 이름")
                        .font(.subheadline.weight(.semibold))
                    TextField(text: $spokenNameDraft) { Text("예: 한글로 쓴 이름") }
                        .focused($focused, equals: .spokenName)
                        .submitLabel(.done)
                        .onSubmit { commit(.spokenName) }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(minHeight: 44)
                }
            }
        } header: {
            Text("호출 이름")
        } footer: {
            Text("쉼표로 구분해요. 이 이름으로 시작하는 말만 에이전트에게 보내요. 안경을 두 번 톡톡 치면 이름 없이 바로 말할 수 있어요.")
        }
    }

    private var deviceSection: some View {
        Section {
            LabeledContent {
                TextField(text: $gatewayNameDraft) { Text("게이트웨이 이름") }
                    .focused($focused, equals: .gatewayName)
                    .submitLabel(.done)
                    .onSubmit { commit(.gatewayName) }
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(Theme.text)
            } label: {
                Text("게이트웨이 이름")
            }
            .frame(minHeight: 44)
            LabeledContent {
                Text(verbatim: DeviceFingerprint.short(runtime.deviceID))
                    .font(.body.monospaced().weight(.semibold))
                    .foregroundStyle(Theme.accent)
            } label: {
                Text("이 기기 지문")
            }
            .frame(minHeight: 44)
            if !runtime.settings.agentName.isEmpty {
                LabeledContent {
                    Text(verbatim: runtime.settings.agentName)
                } label: {
                    Text("에이전트")
                }
                .frame(minHeight: 44)
            }
        } header: {
            Text("기기")
        }
    }

    private var actionsSection: some View {
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
    }

    private var advancedSection: some View {
        Section {
            if runtime.settings.telegramEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    Text("텔레그램 채팅 ID")
                        .font(.subheadline.weight(.semibold))
                    // Numbers-first keyboard: group chat ids start with "-".
                    TextField(text: $chatIDDraft, prompt: Text(verbatim: "123456789")) {
                        Text("텔레그램 채팅 ID")
                    }
                    .focused($focused, equals: .chatID)
                    .submitLabel(.done)
                    .onSubmit { commit(.chatID) }
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    if !chatIDDraft.isEmpty, !CompanionTurnOptions.isTelegramChatID(chatIDDraft) {
                        Text("숫자로 된 채팅 ID를 입력해 주세요")
                            .font(.caption)
                            .foregroundStyle(Theme.problem)
                    } else {
                        Text("에이전트 답을 받을 텔레그램 채팅의 숫자 ID예요")
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }
            Picker(selection: binding(\.wakeSource)) {
                Text("안경 음성 인식 (기본)").tag(WakeSource.glassesSpeech)
                Text("안경 마이크 + iPhone 인식 (실험)").tag(WakeSource.glassesMicOnPhone)
            } label: {
                Text("호출 듣는 방식")
            }
            .onChange(of: runtime.settings.wakeSource) { _, source in
                if source == .glassesMicOnPhone { runtime.requestSpeechRecognition() }
            }
            Picker(selection: binding(\.replyDucking)) {
                Text("끔 (기본)").tag(ReplyDuckingMode.off)
                Text("실험 1: 별도 음성 세션").tag(ReplyDuckingMode.separateSynthesizerSession)
                Text("실험 2: 답할 때 음악 줄이기").tag(ReplyDuckingMode.toggleDuckOthers)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("답할 때 다른 소리 줄이기")
                    Text("실험 기능이에요. 안경 연결이 끊길 수 있어 기본은 꺼져 있어요")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                }
            }
            .pickerStyle(.navigationLink)
            DisclosureGroup(isExpanded: $showFullFingerprint) {
                Text(verbatim: DeviceFingerprint.grouped(runtime.deviceID))
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.secondary)
                    .textSelection(.enabled)
            } label: {
                Text("전체 기기 지문")
            }
            .frame(minHeight: 44)
            .id(Self.advancedID)
        } header: {
            Text("고급")
        }
    }

    private var diagnosticsSection: some View {
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
                .id(AnchoredScrollView<EmptyView>.bottomID)
        }
    }

    // MARK: Commit helpers

    private func commit(_ field: Field?) {
        switch field {
        case .chatID:
            let trimmed = chatIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != runtime.settings.telegramChatID { runtime.settings.telegramChatID = trimmed }
        case .gatewayName:
            let trimmed = gatewayNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let derived = GatewayAddress.defaultName(forGatewayURL: runtime.settings.gatewayURL)
            let custom = trimmed == derived ? "" : trimmed
            if custom != runtime.settings.gatewayName { runtime.settings.gatewayName = custom }
            gatewayNameDraft = runtime.gatewayLabel
        case .spokenName:
            let trimmed = spokenNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != runtime.settings.spokenName { runtime.settings.spokenName = trimmed }
            phrasesText = runtime.settings.effectiveWakePhrases.joined(separator: ", ")
        case .none:
            break
        }
    }

    private func savePhrases() {
        let parsed = WakePhrases.parse(phrasesText)
        let defaults = WakePhrases.defaults(
            agentName: runtime.settings.agentName, spokenName: runtime.settings.spokenName
        )
        runtime.settings.wakePhrases = parsed == defaults ? [] : parsed
        phrasesText = runtime.settings.effectiveWakePhrases.joined(separator: ", ")
    }

    #if DEBUG
    private func applyPreview(_ proxy: ScrollViewProxy) async {
        guard CompanionPreviewFixture.opensSettings else { return }
        showDiagnostics = CompanionPreviewFixture.showsDiagnosticsLink
        showFullFingerprint = CompanionPreviewFixture.expandsFingerprint
        try? await Task.sleep(for: .milliseconds(600))
        if CompanionPreviewFixture.scrollsToBottom || CompanionPreviewFixture.expandsFingerprint {
            // The footer anchor exists only while its section has rows.
            proxy.scrollTo(
                showDiagnostics ? AnchoredScrollView<EmptyView>.bottomID : Self.advancedID,
                anchor: .bottom
            )
            try? await Task.sleep(for: .milliseconds(500))
        }
        switch CompanionPreviewFixture.settingsDialog {
        case .reset: confirmReset = true
        case .reapprove: confirmReapprove = true
        case .none: break
        }
        if CompanionPreviewFixture.opensDiagnostics { openDiagnostics = true }
    }
    #endif

    private static let advancedID = "awl-settings-advanced"

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
                if let latency = runtime.signals.lastReplyLatency {
                    LabeledContent {
                        Text("\(latency, format: .number.precision(.fractionLength(1)))초")
                    } label: {
                        Text("말 끝 → 답 시작")
                    }
                }
            } footer: {
                Text("연결 상태 기록만 담겨요. 토큰과 말한 내용은 기록하지 않아요.")
            }
            Section {
                ForEach(runtime.log.entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.date, format: .dateTime.hour().minute().second())
                            .font(.caption2.monospaced())
                            .foregroundStyle(Theme.tertiary)
                        Text(verbatim: entry.message)
                            .font(.footnote.monospaced())
                            .fixedSize(horizontal: false, vertical: true)
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
