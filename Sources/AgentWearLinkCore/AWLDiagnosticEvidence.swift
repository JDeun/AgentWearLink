import Foundation

/// Explicitly user-exported, structure-only diagnostic evidence.
///
/// No free-form diagnostic fields are representable: token, URI, hostname,
/// prompt, transcript, image bytes, upstream error and session key are all
/// absent by construction. Correlation UUIDs are replaced with locally
/// scoped ordinals that cannot be joined with another export.
public enum AWLDiagnosticEvidence {
    private struct Row: Encodable {
        let kind: AWLDiagnosticKind
        let interactionOrdinal: Int?
        let generation: UInt64?
        let attempt: Int?
    }

    private struct Report: Encodable {
        let schemaVersion: Int
        let isTruncated: Bool
        let droppedEventCount: Int
        let events: [Row]
    }

    public static func export(
        from recorder: AWLDiagnosticRecorder,
        maximumEvents: Int = 128
    ) throws -> String {
        precondition(maximumEvents > 0)
        let snapshot = recorder.snapshot()
        let selected = Array(snapshot.suffix(maximumEvents))
        var ordinals: [InteractionID: Int] = [:]

        let rows = selected.map { event in
            let ordinal: Int?
            if let interactionID = event.interactionID {
                if let existing = ordinals[interactionID] {
                    ordinal = existing
                } else {
                    let next = ordinals.count + 1
                    ordinals[interactionID] = next
                    ordinal = next
                }
            } else {
                ordinal = nil
            }
            return Row(
                kind: event.kind,
                interactionOrdinal: ordinal,
                generation: event.generation,
                attempt: event.attempt
            )
        }

        let report = Report(
            schemaVersion: 1,
            isTruncated: snapshot.count > selected.count
                || recorder.droppedCount > 0,
            droppedEventCount: recorder.droppedCount,
            events: rows
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(report), as: UTF8.self)
    }
}
