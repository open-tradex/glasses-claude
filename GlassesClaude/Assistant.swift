import Foundation
import UIKit

/// Связывает всё вместе: фраза или текст → GPT (быстро) или агент Hermes/Иберика → ответ голосом в очки.
@MainActor
final class Assistant: ObservableObject {
    enum Status: Equatable {
        case off, starting, listening, thinking, speaking
        case error(String)
    }

    @Published private(set) var status: Status = .off
    /// Идёт голосовая сессия с очками (микрофон слушает).
    @Published private(set) var isRunning = false
    /// Сейчас готовится быстрый ответ — новые вопросы пока не принимаем.
    @Published private(set) var isBusy = false
    @Published private(set) var lastQuestion = ""
    @Published private(set) var lastAnswer = ""
    /// Короткая подсказка на главном экране (исчезает сама).
    @Published private(set) var hint: String?
    /// Следующая фраза будет принята без слова-активатора (тап по сфере).
    @Published var forceNextUtterance = false
    /// Сколько поручений агентам сейчас в работе.
    @Published private(set) var agentJobs = 0

    let glasses = GlassesManager()
    let voice = VoiceEngine()
    let library: LibraryStore
    private let settings = AppSettings.shared
    private var hintTask: Task<Void, Never>?

    /// Слова, по которым понятно, что нужен кадр с камеры.
    private let visualCues = ["посмотри", "смотри", "что это", "что я вижу", "видишь", "что передо мной",
                              "опиши", "прочитай", "прочти", "переведи", "сфоткай", "сними", "кадр",
                              "какой шрифт", "какой цвет", "какого цвета", "что за", "палитр", "референс"]
    /// Как распознаватель слышит «Джипити».
    private let wakeWords = ["джипити", "джи пи ти", "gpt", "жпт", "гпт", "chatgpt", "чат джипити"]
    /// Первое слово фразы → агент. Распознаватель коверкает имена, ловим частые варианты.
    private let agentWords: [(String, Brain.Agent)] = [
        ("гермес", .hermes), ("гермиз", .hermes), ("гермис", .hermes), ("hermes", .hermes), ("эрмес", .hermes),
        ("иберик", .iberika), ("иберия", .iberika), ("иберии", .iberika), ("iberik", .iberika), ("ибирик", .iberika),
    ]

    /// После такой паузы разговор начинается заново, в новой теме.
    private let topicIdleInterval: TimeInterval = 30 * 60

    init(library: LibraryStore) {
        self.library = library
        voice.onUtterance = { [weak self] text in self?.handle(utterance: text) }
    }

    // MARK: Голосовая сессия

    func start() async {
        guard !isRunning, status != .starting else { return }
        status = .starting
        GlassesManager.cameraEnabled = settings.cameraOn
        do {
            guard await voice.requestPermissions() else { throw AssistantError.permissions }
            if GlassesManager.cameraEnabled {
                do {
                    try await glasses.ensureCameraPermission()
                } catch {
                    GlassesManager.cameraEnabled = false
                    showHint("Камера очков недоступна — работаю только голосом")
                }
            }
            // Порядок важен: сессия с очками → микрофон (HFP) → поток камеры
            try await glasses.prepareSession()
            try await voice.startAudio(useGlassesMic: settings.useGlassesMic)
            glasses.startStream()
            isRunning = true
            voice.startListening()
            status = isBusy ? .thinking : .listening
            if settings.useGlassesMic && !voice.glassesMicActive {
                showHint("Микрофон очков не подключился — слушаю через iPhone")
            }
        } catch {
            stopVoice()
            status = .error(error.localizedDescription)
        }
    }

    func stop() {
        stopVoice()
        status = isBusy ? .thinking : .off
    }

    private func stopVoice() {
        voice.stopAudio()
        glasses.stop()
        isRunning = false
        forceNextUtterance = false
    }

    /// Тап по сфере во время прослушивания: следующая фраза уйдёт без слова-активатора.
    func listenWithoutWakeWord() {
        guard isRunning else { return }
        forceNextUtterance = true
        showHint("Говори — отправлю следующую фразу целиком")
    }

    func interrupt() {
        voice.stopSpeaking()
    }

    // MARK: Входящие фразы и текст

    /// «Гермес, сделай …» → (.hermes, «сделай …»). Имя агента должно стоять первым словом.
    private func agentRoute(_ text: String) -> (Brain.Agent, String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = trimmed.split(whereSeparator: { !$0.isLetter }).first.map { $0.lowercased() } ?? ""
        guard let agent = agentWords.first(where: { first.hasPrefix($0.0) })?.1,
              let range = trimmed.range(of: first, options: [.caseInsensitive]) else { return nil }
        let rest = String(trimmed[range.upperBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?—-:"))
        return (agent, rest)
    }

    private func wantsImage(_ text: String) -> Bool {
        guard GlassesManager.cameraEnabled else { return false }
        switch settings.imageMode {
        case .always: return true
        case .never: return false
        case .auto:
            let lower = text.lowercased()
            return visualCues.contains { lower.contains($0) }
        }
    }

    private func handle(utterance raw: String) {
        var question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard question.count >= 2 else { return }

        // Поручение агенту: имя агента само по себе активатор
        if let (agent, task) = agentRoute(question) {
            forceNextUtterance = false
            guard !task.isEmpty else { return showHint("Скажи задачу сразу после «\(agent.title)»") }
            delegate(task, to: agent, source: .voice, withImage: wantsImage(task))
            return
        }

        guard !isBusy else { return }
        if settings.requireWakeWord && !forceNextUtterance {
            let found = wakeWords.compactMap {
                question.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive])
            }.first
            guard let range = found else {
                showHint("Не услышал «Джипити» — пропустил: «\(question)»")
                return
            }
            question = String(question[range.upperBound...].drop(while: { $0.isLetter }))
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?—-"))
            if question.isEmpty { question = "Привет!" }
        }
        forceNextUtterance = false
        submit(question, source: .voice, withImage: wantsImage(question))
    }

    /// Текстовое сообщение из приложения. Возвращает id темы, куда оно ушло.
    @discardableResult
    func sendText(_ text: String, inTopic topicId: UUID? = nil) -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let topicId { library.currentTopicId = topicId }
        if let (agent, task) = agentRoute(trimmed), !task.isEmpty {
            return delegate(task, to: agent, source: .text, withImage: false)
        }
        guard !isBusy else { return nil }
        return submit(trimmed, source: .text, withImage: false)
    }

    // MARK: Быстрый ответ GPT

    @discardableResult
    private func submit(_ question: String, source: ChatMessage.Source, withImage: Bool) -> UUID {
        isBusy = true
        status = .thinking
        lastQuestion = question
        library.splitIfIdle(after: topicIdleInterval)
        let history = library.apiHistory()
        let topicId = library.appendToCurrent(ChatMessage(role: .user, text: question, source: source))
        Task { await request(question, topicId: topicId, history: history, source: source, withImage: withImage) }
        return topicId
    }

    private func request(_ question: String, topicId: UUID, history: [Brain.Turn],
                         source: ChatMessage.Source, withImage: Bool) async {
        let image = withImage ? await glasses.snapshot() : nil
        let prompt = (withImage && image == nil)
            ? "\(question)\n[Системная пометка: камера очков сейчас недоступна, изображения нет.]"
            : question
        let client = settings.brain

        do {
            let answer = try await client.send(history: history, userText: prompt, image: image)
            library.append(ChatMessage(role: .assistant, text: answer, source: source), to: topicId)
            lastAnswer = answer
            nameTopicIfNeeded(topicId, question: question, answer: answer, client: client)
            await say(answer)
        } catch {
            let message = error.localizedDescription
            library.append(ChatMessage(role: .assistant, text: message, source: source, isError: true), to: topicId)
            lastAnswer = message
            await say("Не получилось получить ответ. Подробности в приложении.")
        }

        isBusy = false
        if case .error = status { return }
        status = isRunning ? .listening : .off
    }

    // MARK: Поручения агентам

    /// Поручение уходит в фон: сразу «принял», результат озвучиваем, когда придёт. Можно говорить дальше.
    @discardableResult
    private func delegate(_ task: String, to agent: Brain.Agent, source: ChatMessage.Source, withImage: Bool) -> UUID {
        lastQuestion = "\(agent.title): \(task)"
        library.splitIfIdle(after: topicIdleInterval)
        let topicId = library.appendToCurrent(ChatMessage(role: .user, text: "\(agent.title), \(task)", source: source))
        agentJobs += 1
        Task {
            let client = settings.brain
            let image = withImage ? await glasses.snapshot() : nil
            do {
                let (id, ack) = try await client.startAgent(agent, text: task, image: image)
                await say(ack)
                let reply = try await client.waitAgent(id: id)
                library.append(ChatMessage(role: .assistant, text: "\(agent.title): \(reply)", source: source), to: topicId)
                lastAnswer = reply
                await say("\(agent.title) ответил. \(reply)")
            } catch {
                let message = error.localizedDescription
                library.append(ChatMessage(role: .assistant, text: message, source: source, isError: true), to: topicId)
                lastAnswer = message
                await say("\(agent.title) недоступен. Подробности в приложении.")
            }
            agentJobs -= 1
        }
        return topicId
    }

    // MARK: Озвучка

    /// Говорит в очки, если идёт голосовая сессия. Ждёт, пока закончится предыдущая фраза.
    private func say(_ text: String) async {
        guard isRunning else { return }
        await waitUntilSpoken()
        let before = status
        status = .speaking
        voice.speak(text, rate: settings.speechRate)
        await waitUntilSpoken()
        if status == .speaking { status = (before == .thinking && isBusy) ? .thinking : (isRunning ? .listening : .off) }
    }

    /// После первого ответа в теме просим модель придумать ей короткое название.
    private func nameTopicIfNeeded(_ topicId: UUID, question: String, answer: String, client: Brain) {
        guard let topic = library.topic(topicId), !topic.titleIsManual,
              topic.messages.filter({ !$0.isError }).count == 2 else { return }
        Task {
            if let title = try? await client.topicTitle(question: question, answer: answer) {
                library.setAutoTitle(topicId, title)
            }
        }
    }

    private func waitUntilSpoken() async {
        while voice.isSpeaking {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    private func showHint(_ text: String) {
        hint = text
        hintTask?.cancel()
        hintTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.hint = nil
        }
    }
}

enum AssistantError: LocalizedError {
    case permissions

    var errorDescription: String? {
        "Дай доступ к микрофону и распознаванию речи: Настройки iOS → Гермес в очках."
    }
}
