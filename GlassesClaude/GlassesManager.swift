import Foundation
import UIKit
import MWDATCore
import MWDATCamera

/// Всё, что связано с очками: регистрация, разрешение на камеру, сессия, видеопоток, снимки.
@MainActor
final class GlassesManager: ObservableObject {
    enum Phase: Equatable {
        case idle, connecting, waitingForStream, streaming, paused, stopped
        case failed(String)

        var title: String {
            switch self {
            case .idle: return "Не запущено"
            case .connecting: return "Подключаюсь к очкам…"
            case .waitingForStream: return "Запускаю камеру…"
            case .streaming: return "Очки на связи"
            case .paused: return "Пауза (тап по дужке — продолжить)"
            case .stopped: return "Сессия остановлена"
            case .failed(let msg): return "Ошибка: \(msg)"
            }
        }
    }

    @Published private(set) var registration: RegistrationState = .unavailable
    @Published private(set) var deviceCount = 0
    @Published private(set) var cameraGranted = false
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var preview: UIImage?

    private let wearables = Wearables.shared
    private var session: DeviceSession?
    private var camera: Camera?
    private var tokens: [any AnyListenerToken] = []
    private var latestFrame: UIImage?
    private var pendingPhoto: CheckedContinuation<UIImage?, Never>?
    /// Камера очков. Временно выключена — поставь true, чтобы вернуть.
    static var cameraEnabled = true

    private var lastPreviewUpdate = Date.distantPast
    private var streamRetries = 0

    init() {
        Task { [weak self] in
            guard let self else { return }
            for await state in self.wearables.registrationStateStream() {
                self.registration = state
            }
        }
        Task { [weak self] in
            guard let self else { return }
            for await devices in self.wearables.devicesStream() {
                self.deviceCount = devices.count
                self.refreshDiagnostics()
            }
        }
    }

    var isRegistered: Bool { registration == .registered }

    // MARK: Регистрация и разрешения

    func register() async throws {
        try await wearables.startRegistration()
    }

    func handle(url: URL) async {
        _ = try? await wearables.handleUrl(url)
    }

    func ensureCameraPermission() async throws {
        var status = try await wearables.checkPermissionStatus(.camera)
        if status != .granted {
            status = try await wearables.requestPermission(.camera)
        }
        cameraGranted = (status == .granted)
    }

    // MARK: Сессия

    /// Шаг 1: старт сессии и добавление камеры. Поток камеры пока НЕ запускаем:
    /// по правилам SDK сначала нужно поднять микрофон (HFP), потом стартовать поток.
    func prepareSession() async throws {
        phase = .connecting

        // Ждём до 20 секунд, пока очки будут именно ПОДКЛЮЧЕНЫ (не просто известны приложению)
        var target: Device?
        for _ in 0..<40 {
            refreshDiagnostics()
            target = wearables.devices
                .compactMap { wearables.deviceForIdentifier($0) }
                .first { $0.linkState == .connected }
            if target != nil { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        refreshDiagnostics()

        guard let device = target else {
            if wearables.devices.isEmpty { throw GlassesError.noDevice }
            throw GlassesError.notConnected(diagnostics)
        }

        switch device.compatibility() {
        case .deviceUpdateRequired: throw GlassesError.updateGlasses
        case .sdkUpdateRequired: throw GlassesError.updateSDK
        default: break
        }

        // Сессия может не стартовать с первого раза — пробуем 2 раза
        var lastError: Error?
        for attempt in 1...2 {
            do {
                try await startSession(on: device.identifier)
                return
            } catch {
                lastError = error
                print("[Glasses] attempt \(attempt) failed: \(error.localizedDescription)")
                session?.stop()
                session = nil
                if attempt < 2 { try await Task.sleep(nanoseconds: 2_000_000_000) }
            }
        }
        throw lastError ?? GlassesError.noDevice
    }

    /// Строка-диагностика по очкам: имя, связь, совместимость, надеты ли, открыты ли дужки.
    @Published private(set) var diagnostics = "—"

    func refreshDiagnostics() {
        let devices = wearables.devices.compactMap { wearables.deviceForIdentifier($0) }
        guard !devices.isEmpty else { diagnostics = "очков нет в списке"; return }
        diagnostics = devices.map { d in
            let link: String = switch d.linkState {
                case .connected: "связь есть"
                case .connecting: "подключаются"
                case .disconnected: "нет связи"
            }
            let compat: String = switch d.compatibility() {
                case .compatible: "совместимы"
                case .deviceUpdateRequired: "нужно обновить очки"
                case .sdkUpdateRequired: "нужно обновить SDK"
                default: "совместимость неизвестна"
            }
            let worn: String = switch d.donState {
                case .donned: "надеты"
                case .doffed: "сняты"
                default: "ношение ?"
            }
            let hinge: String = switch d.hingeState {
                case .open: "дужки открыты"
                case .closed: "дужки закрыты"
                default: "дужки ?"
            }
            return "\(d.nameOrId()): \(link), \(compat), \(worn), \(hinge)"
        }.joined(separator: "\n")
        print("[Glasses] \(diagnostics)")
    }

    private func startSession(on deviceId: DeviceIdentifier) async throws {
        let session = try wearables.createSession(deviceSelector: SpecificDeviceSelector(device: deviceId))
        self.session = session

        // Запоминаем последнюю ошибку сессии, чтобы показать настоящую причину
        let sessionError = ErrorBox()
        let errorTask = Task { @MainActor in
            for await error in session.errorStream() {
                sessionError.value = error.description
                print("[Glasses] session error: \(error.description)")
            }
        }
        defer { errorTask.cancel() }

        let states = session.stateStream()
        print("[Glasses] starting session, devices: \(wearables.devices.count)")
        try session.start()

        // Ждём .started не дольше 20 секунд
        let started = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await state in states {
                    print("[Glasses] session state: \(state.description)")
                    if state == .started { return true }
                    if state == .stopped { return false }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        guard started else {
            try? await Task.sleep(nanoseconds: 300_000_000) // даём ошибке долететь
            throw GlassesError.sessionFailed(sessionError.value ?? "очки не ответили за 20 секунд (state: \(session.state.description))")
        }

        // Следим за паузой/стопом (тап по дужке, снятие очков, закрытые дужки)
        Task { [weak self] in
            for await state in session.stateStream() {
                guard let self else { return }
                switch state {
                case .paused: self.phase = .paused
                case .started: if self.camera != nil { self.phase = .streaming }
                case .stopped:
                    // Остановили сами кнопкой «Стоп» — session уже nil, ничего не делаем
                    guard self.session === session else { return }
                    self.phase = .stopped
                    self.teardown()
                default: break
                }
            }
        }

        // Камера временно выключена: работаем только с голосом
        guard Self.cameraEnabled else {
            phase = .streaming
            return
        }

        // 504×896 при 7 к/с: меньше сжатия по Bluetooth, картинка чище
        let config = StreamConfiguration(videoCodec: .raw, resolution: .medium, frameRate: 7)
        // Камера не поднялась (права, прошивка) — не роняем сессию, работаем голосом
        guard let camera = try? session.addCamera(config: config) else {
            print("[Glasses] camera unavailable, voice only")
            Self.cameraEnabled = false
            phase = .streaming
            return
        }
        self.camera = camera
        phase = .waitingForStream

        let stream = camera.stream
        tokens.append(stream.videoFramePublisher.listen { [weak self] frame in
            guard let image = frame.makeUIImage() else { return }
            Task { @MainActor in self?.receive(frame: image) }
        })
        tokens.append(stream.photoDataPublisher.listen { [weak self] photo in
            let image = UIImage(data: photo.data)
            Task { @MainActor in self?.receive(photo: image) }
        })
        tokens.append(stream.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .streaming: self.phase = .streaming
                case .paused: self.phase = .paused
                case .waitingForDevice, .starting: self.phase = .waitingForStream
                default: break
                }
            }
        })
        tokens.append(stream.errorPublisher.listen { [weak self] error in
            Task { @MainActor in self?.handleStream(error: error) }
        })
    }

    /// Шаг 2: запуск видеопотока (после того как HFP-микрофон настроен).
    func startStream() {
        streamRetries = 0
        print("[Glasses] starting camera stream")
        camera?.stream.start()
    }

    /// Видеоканал (Wi-Fi между очками и iPhone) иногда поднимается не с первого раза — пробуем ещё 3 раза.
    private func handleStream(error: StreamError) {
        print("[Glasses] stream error: \(error.description)")
        guard camera != nil else { return }
        if streamRetries < 3 {
            streamRetries += 1
            phase = .waitingForStream
            let attempt = streamRetries
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, let stream = self.camera?.stream else { return }
                print("[Glasses] retry camera stream #\(attempt)")
                stream.stop()
                try? await Task.sleep(nanoseconds: 500_000_000)
                stream.start()
            }
        } else {
            phase = .failed("камера: \(error.description). Проверь «Локальная сеть» для приложения и VPN (Allow LAN).")
        }
    }

    func stop() {
        camera?.stop()
        session?.stop()
        teardown()
        phase = .idle
    }

    private func teardown() {
        let old = tokens
        tokens.removeAll()
        Task { for t in old { await t.cancel() } }
        camera = nil
        session = nil
        pendingPhoto?.resume(returning: latestFrame)
        pendingPhoto = nil
    }

    // MARK: Кадры

    private func receive(frame: UIImage) {
        latestFrame = frame
        // Превью в интерфейсе обновляем не чаще 2 раз в секунду
        if Date().timeIntervalSince(lastPreviewUpdate) > 0.5 {
            preview = frame
            lastPreviewUpdate = Date()
        }
    }

    private func receive(photo: UIImage?) {
        if let photo { preview = photo }
        pendingPhoto?.resume(returning: photo ?? latestFrame)
        pendingPhoto = nil
    }

    /// Снимок «что я вижу»: пробует сделать фото из потока, при неудаче отдаёт последний кадр.
    func snapshot(timeout: TimeInterval = 3) async -> UIImage? {
        guard let stream = camera?.stream, phase == .streaming else { return latestFrame }
        if pendingPhoto != nil { return latestFrame }

        return await withCheckedContinuation { continuation in
            pendingPhoto = continuation
            if !stream.capturePhoto(format: .jpeg) {
                pendingPhoto = nil
                continuation.resume(returning: latestFrame)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, let pending = self.pendingPhoto else { return }
                self.pendingPhoto = nil
                pending.resume(returning: self.latestFrame)
            }
        }
    }
}

private final class ErrorBox: @unchecked Sendable {
    var value: String?
}

enum GlassesError: LocalizedError {
    case sessionStopped, cameraUnavailable, noDevice
    case sessionFailed(String)
    case notConnected(String)
    case updateGlasses, updateSDK

    var errorDescription: String? {
        switch self {
        case .notConnected(let info): return "Очки найдены, но не на связи. Открой Meta AI (не закрывай его), дождись подключения и нажми «Начать» снова.\n\(info)"
        case .updateGlasses: return "Нужно обновить прошивку очков: Meta AI → очки → настройки → обновление."
        case .updateSDK: return "Очкам нужна более новая версия SDK — обнови приложение."
        case .sessionFailed(let reason): return "Очки не запустили сессию: \(reason)"
        case .noDevice: return "Очки не видны приложению. Открой Meta AI и проверь, что очки подключены, надеты и дужки открыты."
        case .sessionStopped: return "Сессия с очками остановилась. Проверь, что очки надеты и дужки открыты."
        case .cameraUnavailable: return "Не удалось получить камеру очков."
        }
    }
}
