import Foundation
import AVFoundation
import Speech

/// Голос: микрофоны очков (Bluetooth HFP) → распознавание русской речи → готовая фраза.
/// И обратно: синтез речи → динамики очков.
@MainActor
final class VoiceEngine: NSObject, ObservableObject {
    @Published private(set) var liveTranscript = ""
    @Published private(set) var isListening = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var inputRoute = "—"

    /// Вызывается, когда пользователь договорил фразу (после паузы ~1,2 с).
    var onUtterance: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    private let synthesizer = AVSpeechSynthesizer()

    private let requestLock = NSLock()
    private nonisolated(unsafe) var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var taskStartedAt = Date()
    private var taskGeneration = 0
    private var speechRate: Float = 0.52

    private let silenceInterval: TimeInterval = 1.2
    /// Apple ограничивает одну задачу распознавания ~1 минутой — перезапускаем заранее.
    private let maxTaskDuration: TimeInterval = 50

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: Разрешения

    func requestPermissions() async -> Bool {
        let mic = await withCheckedContinuation { c in
            AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
        }
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        return mic && speech
    }

    // MARK: Аудио-сессия (HFP через очки)

    /// Настраивает HFP, выбирает микрофон очков, запускает движок и ждёт, пока маршрут «устаканится».
    /// useGlassesMic = false: слушаем микрофоном iPhone, а ответ играет в очки по A2DP (качественный звук).
    func startAudio(useGlassesMic: Bool) async throws {
        let session = AVAudioSession.sharedInstance()
        if useGlassesMic {
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
        } else {
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP])
        }
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        if useGlassesMic {
            if let hfp = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
                try session.setPreferredInput(hfp)
            }
        } else if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try session.setPreferredInput(builtIn)
        }

        let input = audioEngine.inputNode
        let format = input.inputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()

        // SDK рекомендует подождать ~2 с, прежде чем запускать поток камеры
        try await Task.sleep(nanoseconds: 2_000_000_000)
        updateRouteName()
    }

    func stopAudio() {
        stopListening()
        synthesizer.stopSpeaking(at: .immediate)
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        inputRoute = "—"
    }

    var glassesMicActive: Bool {
        AVAudioSession.sharedInstance().currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
    }

    private func updateRouteName() {
        let inputs = AVAudioSession.sharedInstance().currentRoute.inputs
        inputRoute = inputs.first.map { "\($0.portName) (\($0.portType == .bluetoothHFP ? "очки" : "телефон"))" } ?? "—"
    }

    private nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        requestLock.lock()
        request?.append(buffer)
        requestLock.unlock()
    }

    // MARK: Распознавание

    func startListening() {
        guard !isSpeaking, let recognizer, recognizer.isAvailable else { return }
        stopTask()

        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            newRequest.requiresOnDeviceRecognition = true
        }
        requestLock.lock()
        request = newRequest
        requestLock.unlock()

        liveTranscript = ""
        taskStartedAt = Date()
        isListening = true
        taskGeneration += 1
        let generation = taskGeneration

        task = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor in
                // События от старых (уже отменённых) задач игнорируем
                guard let self, generation == self.taskGeneration else { return }
                if let text, !text.isEmpty {
                    self.liveTranscript = text
                    self.restartSilenceTimer()
                }
                if isFinal || error != nil {
                    // Задача закончилась сама (тайм-аут Apple или ошибка) — перезапускаем
                    if !self.isSpeaking && self.isListening && self.liveTranscript.isEmpty {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        if generation == self.taskGeneration && self.isListening && !self.isSpeaking {
                            self.startListening()
                        }
                    }
                }
            }
        }
    }

    func stopListening() {
        isListening = false
        stopTask()
    }

    private func stopTask() {
        taskGeneration += 1
        silenceTimer?.invalidate()
        silenceTimer = nil
        requestLock.lock()
        request?.endAudio()
        request = nil
        requestLock.unlock()
        task?.cancel()
        task = nil
    }

    private func restartSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finishUtterance() }
        }
        // Задача живёт слишком долго — закрываем фразу принудительно
        if Date().timeIntervalSince(taskStartedAt) > maxTaskDuration {
            finishUtterance()
        }
    }

    private func finishUtterance() {
        let text = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        stopTask()
        liveTranscript = ""
        if !text.isEmpty { onUtterance?(text) }
        // Если ответ не начался (фраза без активатора), продолжаем слушать
        if isListening && !isSpeaking { startListening() }
    }

    // MARK: Речь

    func speak(_ text: String, rate: Double) {
        stopTask() // не слушаем сами себя
        isSpeaking = true
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ru-RU")
        utterance.rate = Float(rate)
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    fileprivate func didFinishSpeaking() {
        isSpeaking = false
        // Небольшая пауза, чтобы хвост ответа не попал в микрофон
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if self.isListening { self.startListening() }
        }
    }
}

extension VoiceEngine: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.didFinishSpeaking() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.didFinishSpeaking() }
    }
}
