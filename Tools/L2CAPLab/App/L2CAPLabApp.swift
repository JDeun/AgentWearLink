import SwiftUI

@main
struct L2CAPLabApp: App {
    var body: some Scene {
        WindowGroup { LabView() }
    }
}

struct LabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var radio = LabRadio()
    @State private var consent = false
    @State private var confirmed = false
    @State private var invitation = ""
    @State private var size: LabSize = .small

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("L2CAP Lab").font(.largeTitle)
                Text("Owned iPhone and Mac fixture only. No Meta devices. Local invitation and encryption do not authenticate peers.")
                Toggle("I control both devices, authorize this lab run and any OS security prompt", isOn: $consent)
                    .disabled(radio.busy || radio.retiring)
                #if os(macOS)
                Picker("Fixture bytes", selection: $size) {
                    ForEach(LabSize.allCases, id: \.self) { value in
                        Text(String(value.rawValue)).tag(value)
                    }
                }.disabled(radio.busy || radio.retiring)
                Button("Publish encrypted lab listener") {
                    radio.startServer(size: size, consent: consent)
                }.disabled(!consent || radio.busy || radio.retiring || scenePhase != .active)
                if let local = radio.localInvitation {
                    Text("Local-only invitation — never share in reports").font(.caption)
                    Text(local).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                if radio.canAccept {
                    Button("Accept — I confirmed my iPhone just connected") {
                        radio.acceptIncoming(consent: consent)
                    }.disabled(!consent || scenePhase != .active)
                }
                #else
                TextField("Exact invitation from owned Mac", text: $invitation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(radio.busy || radio.retiring)
                    .textFieldStyle(.roundedBorder)
                Button("Scan lab service") {
                    confirmed = false
                    radio.startCentral(text: invitation, consent: consent)
                    invitation = ""
                }.disabled(!consent || LabInvitation(invitation) == nil || radio.busy || radio.retiring || scenePhase != .active)
                if radio.canConnect {
                    Toggle("I independently confirmed the owned Mac fixture", isOn: $confirmed)
                    Button("Connect to confirmed fixture") {
                        radio.connectConfirmed(consent: consent && confirmed)
                    }.disabled(!consent || !confirmed || scenePhase != .active)
                }
                #endif
                Button("Stop", role: .cancel) {
                    radio.stop()
                    consent = false
                    confirmed = false
                    invitation = ""
                }.disabled(!radio.busy)
                Text(radio.status).font(.headline)
                if radio.retiring { Text("Retiring listener; no new run yet.").font(.caption) }
                Text("Sanitized report").font(.headline)
                Text(radio.report).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }.padding(20)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { clear() }
        }
        .onDisappear { clear() }
    }

    private func clear() {
        radio.stop()
        consent = false
        confirmed = false
        invitation = ""
    }
}
