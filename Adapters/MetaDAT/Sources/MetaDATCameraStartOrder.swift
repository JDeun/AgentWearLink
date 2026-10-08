/// Synchronously arms a vendor media observer before the operation that may
/// deliver its first event. The resulting stream buffers an immediate callback
/// even if it fires before an async consumer starts awaiting next().
enum MetaDATCameraStartOrder {
    static func armBeforeStart<Observation>(
        observe: () -> Observation,
        start: () -> Void
    ) -> Observation {
        let observation = observe()
        start()
        return observation
    }
}
