import CallKit
import Foundation

/// Reports whether any call (phone, FaceTime, CallKit VoIP apps) is active.
final class CallMonitor: NSObject, CXCallObserverDelegate {
    private let observer = CXCallObserver()
    var onChange: ((Bool) -> Void)?

    override init() {
        super.init()
        observer.setDelegate(self, queue: .main)
    }

    var isCallActive: Bool { observer.calls.contains { !$0.hasEnded } }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        onChange?(callObserver.calls.contains { !$0.hasEnded })
    }
}
