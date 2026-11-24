import SwiftUI

@main
struct BLEDiscoveryApp: App {
    var body: some Scene {
        WindowGroup { ProbeView() }
    }
}

struct ProbeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var probe = BLEProbe()
    @State private var service = ""
    @State private var ownerConsent = false
    @State private var identified = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Owner-only research") {
                    Text("Foreground discovery only. No connection, pairing, GATT I/O, L2CAP, wake enrollment or audio. A match is not proof of transport access.")
                    TextField("Documented service UUID", text: $service)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(probe.session.status.isActive)
                    Toggle("I own the test device and am authorized to observe this service", isOn: $ownerConsent)
                        .disabled(probe.session.status.isActive)
                    Button("Start bounded discovery (15 s)") {
                        identified = false
                        probe.start(service: service, ownerConsent: ownerConsent)
                    }
                    .disabled(scenePhase != .active || !ownerConsent
                              || ServiceFilter.normalized(service) == nil || probe.session.status.isActive)
                    Button("Stop", role: .cancel) { probe.stop() }
                        .disabled(!probe.session.status.isActive)
                    Button("Clear all evidence", role: .destructive) { clear() }
                }
                Section("Local candidates — never exported") {
                    if probe.session.candidates.isEmpty { Text("No retained candidates") }
                    if probe.session.status == .completed {
                        Toggle("I independently identified my own device; name alone is not proof", isOn: $identified)
                    }
                    ForEach(probe.session.candidates) { candidate in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Candidate \(candidate.id)").font(.headline)
                            if let label = candidate.localLabel {
                                Text(label).font(.caption)
                            }
                            Text("Advertisement: \(candidate.advertisement ? "yes" : "not observed")")
                            Text("OS connected snapshot: \(candidate.systemConnectedSnapshot ? "yes" : "not observed")")
                            if probe.session.status == .completed {
                                Button(probe.session.confirmedID == candidate.id ? "Confirmed locally" : "Confirm owned device") {
                                    probe.confirm(candidate: candidate.id, independentlyIdentified: identified)
                                }
                                .disabled(!identified)
                            }
                        }
                    }
                }
                Section("Sanitized report") {
                    Text(probe.session.report)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Text("Copy only this report. No match is inconclusive; service visibility does not establish permission to open a channel.")
                        .font(.caption)
                }
            }
            .navigationTitle("BLE Discovery")
        }
        // Permission prompts may interrupt the first run; explicitly retry
        // after returning to active. Never resume a scan automatically.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { clear() }
        }
        .onDisappear { clear() }
    }

    private func clear() {
        probe.clear()
        service = ""
        ownerConsent = false
        identified = false
    }
}
