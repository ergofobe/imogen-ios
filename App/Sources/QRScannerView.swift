@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// A capture session is thread-safe and has never been marked `Sendable`, and moving one
/// onto a background queue to start it is the documented thing to do. This says so once,
/// rather than at each of the two call sites.
private struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// The camera, looking for one square.
///
/// `AVCaptureMetadataOutput` reads QR codes itself, in hardware, on every iPhone made this
/// decade — so there is no decoder here and no dependency that would need one.
struct QRScannerView: UIViewControllerRepresentable {
    let onScanned: (String) -> Void
    let onUnavailable: () -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onScanned = onScanned
        controller.onUnavailable = onUnavailable
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController {
        var onScanned: ((String) -> Void)?
        var onUnavailable: (() -> Void)?

        /// `AVCaptureSession` is thread-safe but has never been marked `Sendable`, and it
        /// is touched from `sessionQueue` on purpose: starting one blocks for long enough
        /// to drop frames, and the system says so in the console if it happens on main.
        private nonisolated(unsafe) let capture = AVCaptureSession()
        private let sessionQueue = DispatchQueue(label: "com.imogen.ios.capture")

        private var preview: AVCaptureVideoPreviewLayer?
        private lazy var reader = MetadataReader { [weak self] code in
            self?.found(code)
        }
        /// Latched, because the camera will happily read the same code thirty times a
        /// second and every one of them would start pairing again.
        private var handled = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black

            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                configure()
            case .notDetermined:
                Task { @MainActor in
                    if await AVCaptureDevice.requestAccess(for: .video) {
                        configure()
                    } else {
                        onUnavailable?()
                    }
                }
            default:
                onUnavailable?()
            }
        }

        private func configure() {
            guard let device = AVCaptureDevice.default(for: .video),
                let input = try? AVCaptureDeviceInput(device: device),
                capture.canAddInput(input)
            else {
                onUnavailable?()
                return
            }
            capture.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard capture.canAddOutput(output) else {
                onUnavailable?()
                return
            }
            capture.addOutput(output)
            output.setMetadataObjectsDelegate(reader, queue: .main)
            // Set after the output is attached: the available types are not known until
            // the session knows what it is capturing from.
            output.metadataObjectTypes = [.qr]

            let layer = AVCaptureVideoPreviewLayer(session: capture)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.addSublayer(layer)
            preview = layer

            start()
        }

        private func found(_ code: String) {
            guard !handled else { return }
            handled = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onScanned?(code)
        }

        private func start() {
            let session = Unchecked(capture)
            sessionQueue.async { session.value.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            let session = Unchecked(capture)
            sessionQueue.async { session.value.stopRunning() }
        }
    }
}

/// The delegate, kept apart from the view controller.
///
/// `AVCaptureMetadataOutputObjectsDelegate` is not main-actor isolated and a
/// `UIViewController` is, so a controller conforming to it directly is a data race the
/// compiler is right to complain about. This is delivered on the main queue — which is
/// what `setMetadataObjectsDelegate(_:queue:)` was told — so the hop is an assertion
/// rather than a dispatch.
private final class MetadataReader: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    private let onScanned: @MainActor @Sendable (String) -> Void

    init(onScanned: @escaping @MainActor @Sendable (String) -> Void) {
        self.onScanned = onScanned
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput objects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let code = objects
            .compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
            .first?.stringValue
        else { return }

        let deliver = onScanned
        MainActor.assumeIsolated { deliver(code) }
    }
}
