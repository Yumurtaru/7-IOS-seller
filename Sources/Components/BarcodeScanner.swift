import SwiftUI
import UIKit
import AVFoundation
import VisionKit
import Vision

// ============================================================================
//  Сканер штрихкода камерой (паритет с Android ui/scanner/BarcodeScannerDialog.kt).
//  Основной путь — VisionKit DataScannerViewController (iOS 16, A12+).
//  Запасной — AVCaptureSession + AVCaptureMetadataOutput (A11 и старше).
//  Что считать кодом и как его чистить — в Core/BarcodeLogic.swift.
//  Форматы: EAN-13, EAN-8, UPC-A (приходит как EAN-13), UPC-E, Code128, Code39,
//  Code93, ITF, DataMatrix. QR и PDF417 не включаем.
// ============================================================================

/// Фонарик. Ошибки молча: на устройстве без вспышки кнопки просто нет.
enum BarcodeTorch {
    static var isAvailable: Bool {
        AVCaptureDevice.default(for: .video)?.hasTorch ?? false
    }

    static func set(_ on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            let mode: AVCaptureDevice.TorchMode = on ? .on : .off
            if device.isTorchModeSupported(mode) { device.torchMode = mode }
            device.unlockForConfiguration()
        } catch {
            // Не вышло включить — экран остаётся рабочим.
        }
    }
}

/// UIKit-экран камеры. Все делегаты — здесь, на главном потоке: так не нужны
/// пометки изоляции, а DataScannerViewController и его делегат живут на главном потоке.
final class BarcodeScannerViewController: UIViewController, DataScannerViewControllerDelegate, AVCaptureMetadataOutputObjectsDelegate {
    /// Вызывается один раз, когда код подтверждён (главный поток).
    var onResult: ((BarcodeScanResult) -> Void)?

    private var confirmer = BarcodeLogic.Confirmer()
    private var finished = false
    private var started = false

    // VisionKit
    private var scanner: DataScannerViewController?
    private var current: [RecognizedItem] = []
    private var pollTask: Task<Void, Never>?

    // AVFoundation
    private var session: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let sessionQueue = DispatchQueue(label: "ru.marketplace.business.barcode.session")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !started {
            started = true
            start()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stop()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    // ── Запуск и остановка ───────────────────────────────────────────────────
    private func start() {
        finished = false
        confirmer.reset()
        if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
            if startDataScanner() { return }
        }
        startCapture()
    }

    private func stop() {
        pollTask?.cancel()
        pollTask = nil
        if let s = scanner {
            s.stopScanning()
            s.willMove(toParent: nil)
            s.view.removeFromSuperview()
            s.removeFromParent()
        }
        scanner = nil
        current = []
        if let running = session {
            sessionQueue.async { running.stopRunning() }
        }
        previewLayer?.removeFromSuperlayer()
        previewLayer = nil
        session = nil
        started = false
    }

    // ── VisionKit ────────────────────────────────────────────────────────────
    private func startDataScanner() -> Bool {
        let symbologies: [VNBarcodeSymbology] = [.ean13, .ean8, .upce, .code128, .code39,
                                                 .code93, .itf14, .i2of5, .dataMatrix]
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: symbologies)],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighlightingEnabled: true)
        vc.delegate = self
        addChild(vc)
        vc.view.frame = view.bounds
        vc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(vc.view)
        vc.didMove(toParent: self)
        do {
            try vc.startScanning()
        } catch {
            // Не запустился — уходим на запасной путь через AVFoundation.
            vc.willMove(toParent: nil)
            vc.view.removeFromSuperview()
            vc.removeFromParent()
            return false
        }
        scanner = vc
        startPolling()
        return true
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
        current = allItems
        ingest(allItems, includeLinear: false)
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) {
        current = allItems
        ingest(allItems, includeLinear: false)
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didRemove removedItems: [RecognizedItem], allItems: [RecognizedItem]) {
        current = allItems
    }

    /// DataScanner сообщает о коде один раз, а не каждым кадром. Линейный код подтверждаем
    /// опросом: он должен оставаться в кадре на двух проверках подряд (раз в 0,3 с) —
    /// это и есть «два одинаковых чтения»; DataMatrix принимается сразу.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let strongSelf = self else { return }
                strongSelf.ingest(strongSelf.current, includeLinear: true)
            }
        }
    }

    private func ingest(_ items: [RecognizedItem], includeLinear: Bool) {
        for item in items {
            guard case .barcode(let b) = item, let payload = b.payloadStringValue else { continue }
            let symbology = b.observation.symbology
            let kind: BarcodeKind
            if symbology == .dataMatrix {
                kind = .dataMatrix
            } else if symbology == .upce {
                kind = .upce
            } else if symbology == .ean13 || symbology == .ean8 {
                kind = .gtin
            } else if symbology == .itf14 || symbology == .i2of5 {
                kind = .itf
            } else {
                kind = .other
            }
            if kind != .dataMatrix && !includeLinear { continue }
            feed(raw: payload, kind: kind)
        }
    }

    // ── AVFoundation (запасной путь) ─────────────────────────────────────────
    private func startCapture() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        let newSession = AVCaptureSession()
        guard newSession.canAddInput(input) else { return }
        newSession.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard newSession.canAddOutput(output) else { return }
        newSession.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        // Типы задаём ПОСЛЕ addOutput: до этого availableMetadataObjectTypes пуст.
        let wanted: [AVMetadataObject.ObjectType] = [.ean13, .ean8, .upce, .code128, .code39,
                                                     .code93, .itf14, .interleaved2of5, .dataMatrix]
        let available = output.availableMetadataObjectTypes
        output.metadataObjectTypes = wanted.filter { available.contains($0) }

        let layer = AVCaptureVideoPreviewLayer(session: newSession)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
        session = newSession
        // startRunning блокирует поток — не на главном.
        sessionQueue.async { newSession.startRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        for object in metadataObjects {
            guard let code = object as? AVMetadataMachineReadableCodeObject,
                  let payload = code.stringValue else { continue }
            let kind: BarcodeKind
            if code.type == .dataMatrix {
                kind = .dataMatrix
            } else if code.type == .upce {
                kind = .upce
            } else if code.type == .ean13 || code.type == .ean8 {
                kind = .gtin
            } else if code.type == .itf14 || code.type == .interleaved2of5 {
                kind = .itf
            } else {
                kind = .other
            }
            feed(raw: payload, kind: kind)
        }
    }

    // ── Общее ────────────────────────────────────────────────────────────────
    private func feed(raw: String, kind: BarcodeKind) {
        if finished { return }
        guard let result = BarcodeLogic.normalize(raw, kind: kind) else { return }
        guard confirmer.accept(result.value, kind: kind, now: ProcessInfo.processInfo.systemUptime) else { return }
        finished = true
        onResult?(result)
    }
}

/// Обёртка для SwiftUI.
struct BarcodeScannerRepresentable: UIViewControllerRepresentable {
    let onResult: (BarcodeScanResult) -> Void

    func makeUIViewController(context: Context) -> BarcodeScannerViewController {
        let vc = BarcodeScannerViewController()
        vc.onResult = onResult
        return vc
    }

    func updateUIViewController(_ vc: BarcodeScannerViewController, context: Context) {
        vc.onResult = onResult
    }
}

/// Состояние экрана: разрешение камеры и фонарик.
@MainActor
final class BarcodeScannerModel: ObservableObject {
    enum Phase { case checking, ready, denied, noCamera }

    @Published private(set) var phase: Phase = .checking
    @Published private(set) var torchAvailable = false
    @Published private(set) var torchOn = false

    func prepare() async {
        if phase == .ready { return }
        guard AVCaptureDevice.default(for: .video) != nil else { phase = .noCamera; return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted { phase = .denied; return }
        default:
            phase = .denied
            return
        }
        torchAvailable = BarcodeTorch.isAvailable
        phase = .ready
    }

    func toggleTorch() {
        torchOn.toggle()
        BarcodeTorch.set(torchOn)
    }

    func torchOff() {
        if torchOn { torchOn = false }
        BarcodeTorch.set(false)
    }
}

/// Полноэкранный сканер. Успех: короткая вибрация, экран закрывается, код уходит в onScan.
struct BarcodeScannerScreen: View {
    let onScan: (BarcodeScanResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = BarcodeScannerModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
            VStack {
                HStack {
                    Text("Сканировать штрихкод")
                        .font(.headline)
                        .foregroundColor(.white)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white)
                    }
                    .accessibilityLabel("Закрыть")
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                Spacer()
                if model.phase == .ready && model.torchAvailable {
                    Button { model.toggleTorch() } label: {
                        Label("Фонарик", systemImage: model.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(model.torchOn ? Brand.accent : Color.white.opacity(0.25), in: Capsule())
                    }
                    .padding(.bottom, 28)
                }
            }
        }
        .task { await model.prepare() }
        // Вернулись из «Настроек» с разрешённой камерой — запускаем снова.
        .onChange(of: scenePhase) { phase in
            if phase == .active && model.phase == .denied {
                Task { await model.prepare() }
            }
        }
        .onDisappear { model.torchOff() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .checking:
            ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
        case .ready:
            BarcodeScannerRepresentable(onResult: handle)
                .ignoresSafeArea()
            viewfinder
        case .denied:
            VStack(spacing: 16) {
                Text("Нет доступа к камере. Разрешите камеру в настройках, чтобы сканировать штрихкоды.")
                    .font(.body)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                Button("Открыть настройки") { openSettings() }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.accent)
            }
            .padding(32)
        case .noCamera:
            Text("Камера недоступна на этом устройстве")
                .font(.body)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(32)
        }
    }

    /// Рамка по центру и подпись. Касания не перехватывает.
    private var viewfinder: some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white, lineWidth: 3)
                .frame(width: 280, height: 180)
            Text("Наведите камеру на штрихкод")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.5), in: Capsule())
        }
        .allowsHitTesting(false)
    }

    private func handle(_ result: BarcodeScanResult) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onScan(result)
        dismiss()
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

/// Кнопка-иконка «Сканировать штрихкод» со своим полноэкранным листом
/// (отдельная вью — у карточки товара уже есть свой fullScreenCover для фото).
struct BarcodeScanButton: View {
    let onScan: (BarcodeScanResult) -> Void
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            Image(systemName: "barcode.viewfinder")
                .font(.title3)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.borderless)
        .tint(Brand.accent)
        .accessibilityLabel("Сканировать штрихкод")
        .fullScreenCover(isPresented: $show) {
            BarcodeScannerScreen(onScan: onScan)
        }
    }
}
