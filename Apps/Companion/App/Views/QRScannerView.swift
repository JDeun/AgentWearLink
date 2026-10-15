import AVFoundation
import SwiftUI
import UIKit

/// Camera preview that reports the first QR payload. Camera access is
/// requested only when this view appears (the scan step) and released as
/// soon as it disappears.
struct QRScannerView: UIViewControllerRepresentable {
    enum Failure { case denied, unavailable }

    let onCode: (String) -> Void
    let onFailure: (Failure) -> Void
    /// Camera lifecycle notes for the diagnostics log (never the payload).
    var onEvent: (String) -> Void = { _ in }

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        controller.onFailure = onFailure
        controller.onEvent = onEvent
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        var onFailure: ((Failure) -> Void)?
        var onEvent: ((String) -> Void)?
        private let session = AVCaptureSession()
        /// The controller's view *is* the preview layer (Apple's PreviewView
        /// pattern), so it always has the view's size. A sublayer sized by hand
        /// in viewDidLayoutSubviews stayed invisible inside SwiftUI.
        private final class PreviewView: UIView {
            override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
            var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        }
        private var previewView: PreviewView { view as! PreviewView }
        private var delivered = false
        private var configured = false
        private var observers: [NSObjectProtocol] = []
        private let queue = DispatchQueue(label: "dev.agentwearlink.companion.qr")

        override func loadView() {
            view = PreviewView()
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            onEvent?("authorization \(status.rawValue)")
            switch status {
            case .authorized:
                configure()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    DispatchQueue.main.async {
                        granted ? self.configure() : self.onFailure?(.denied)
                    }
                }
            default:
                onFailure?(.denied)
            }
        }

        private func configure() {
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                      ?? AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: camera),
                  session.canAddInput(input) else {
                onEvent?("no usable camera input")
                onFailure?(.unavailable)
                return
            }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                onFailure?(.unavailable)
                return
            }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            previewView.previewLayer.session = session
            previewView.previewLayer.videoGravity = .resizeAspectFill
            configured = true
            observeSession()
            start()
        }

        /// SwiftUI can make the controller disappear and reappear (tab and
        /// picker changes, sheet transitions). The session is stopped on
        /// disappear, so it must be started again here or the preview stays
        /// black.
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            if configured { start() }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            queue.async { [session] in session.stopRunning() }
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        private func start() {
            guard !delivered else { return }
            queue.async { [weak self, session] in
                if !session.isRunning { session.startRunning() }
                let running = session.isRunning
                DispatchQueue.main.async { self?.onEvent?(running ? "running" : "did not start") }
            }
        }

        private func observeSession() {
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main
            ) { [weak self] note in
                let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int).map(String.init) ?? "?"
                self?.onEvent?("interrupted reason=\(reason)")
            })
            observers.append(center.addObserver(
                forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main
            ) { [weak self] _ in
                self?.onEvent?("interruption ended")
                self?.start()
            })
            observers.append(center.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main
            ) { [weak self] note in
                let code = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.code ?? 0
                self?.onEvent?("runtime error \(code)")
                self?.start()
            })
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !delivered,
                  let code = metadataObjects
                      .compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue })
                      .first else { return }
            delivered = true
            queue.async { [session] in session.stopRunning() }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onCode?(code)
        }
    }
}
