import SwiftUI
import AVFoundation
import PhotosUI
import CoreImage

// MARK: live camera scanner
final class QRScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var done = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }
        let p = AVCaptureVideoPreviewLayer(session: session)
        p.videoGravity = .resizeAspectFill
        view.layer.addSublayer(p)
        preview = p
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); if session.isRunning { session.stopRunning() } }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !done, let obj = objects.first as? AVMetadataMachineReadableCodeObject, let s = obj.stringValue else { return }
        done = true
        session.stopRunning()
        onCode?(s)
    }
}

struct CameraScanView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    func makeUIViewController(context: Context) -> QRScannerVC { let vc = QRScannerVC(); vc.onCode = onCode; return vc }
    func updateUIViewController(_ vc: QRScannerVC, context: Context) {}
}

// MARK: decode QR from a picked photo
enum QRImage {
    static func decode(_ image: UIImage) -> String? {
        guard let ci = CIImage(image: image) else { return nil }
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(),
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        for f in detector?.features(in: ci) ?? [] {
            if let q = f as? CIQRCodeFeature, let m = q.messageString { return m }
        }
        return nil
    }
}

struct PhotoQRPicker: UIViewControllerRepresentable {
    let onResult: (String?) -> Void
    func makeCoordinator() -> Coord { Coord(onResult: onResult) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration(); cfg.filter = .images; cfg.selectionLimit = 1
        let vc = PHPickerViewController(configuration: cfg); vc.delegate = context.coordinator; return vc
    }
    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}
    final class Coord: NSObject, PHPickerViewControllerDelegate {
        let onResult: (String?) -> Void
        init(onResult: @escaping (String?) -> Void) { self.onResult = onResult }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let p = results.first?.itemProvider, p.canLoadObject(ofClass: UIImage.self) else { onResult(nil); return }
            p.loadObject(ofClass: UIImage.self) { obj, _ in
                let code = (obj as? UIImage).flatMap { QRImage.decode($0) }
                DispatchQueue.main.async { self.onResult(code) }
            }
        }
    }
}

// MARK: combined sign-in QR sheet (camera + photo)
struct QrSignInSheet: View {
    let onParsed: (QrSignIn) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showPhoto = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                CameraScanView { raw in handle(raw) }.ignoresSafeArea()
                VStack {
                    Spacer()
                    if let error { Text(error).font(.footnote).foregroundColor(.white).padding(8).background(.black.opacity(0.6)).cornerRadius(8) }
                    Button { showPhoto = true } label: {
                        Label("Scan from photo", systemImage: "photo")
                            .padding().background(.white).cornerRadius(10)
                    }.padding(.bottom, 40)
                }
            }
            .navigationTitle("Scan QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $showPhoto) {
                PhotoQRPicker { code in
                    if let code { handle(code) } else { error = "No QR code found in the image." }
                }
            }
        }
    }

    private func handle(_ raw: String) {
        if let parsed = QrParser.parse(raw) { onParsed(parsed); dismiss() }
        else { error = "Couldn't read sign-in details from that QR." }
    }
}
