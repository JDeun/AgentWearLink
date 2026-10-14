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

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        controller.onFailure = onFailure
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        var onFailure: ((Failure) -> Void)?
        private let session = AVCaptureSession()
        private var previewLayer: AVCaptureVideoPreviewLayer?
        private var delivered = false
        private let queue = DispatchQueue(label: "dev.agentwearlink.companion.qr")

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            switch AVCaptureDevice.authorizationStatus(for: .video) {
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
            guard let camera = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: camera),
                  session.canAddInput(input) else {
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
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.addSublayer(layer)
            previewLayer = layer
            queue.async { [session] in session.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            queue.async { [session] in session.stopRunning() }
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
