import SwiftUI
import MWDATCore

struct TopicRef: Identifiable, Hashable {
    let id: UUID
}

/// Главный экран: сфера, состояние, текущая тема и поле ввода.
struct ContentView: View {
    @ObservedObject var assistant: Assistant
    @ObservedObject var glasses: GlassesManager
    @ObservedObject var voice: VoiceEngine
    @ObservedObject var settings: AppSettings
    @ObservedObject var library: LibraryStore

    @State private var showSettings = false
    @State private var showLibrary = false
    @State private var openTopic: TopicRef?
    @State private var draft = ""
    @State private var errorText: String?
    @FocusState private var inputFocused: Bool

    var body: some View {
        ZStack {
            AppBackground()
                .onTapGesture { inputFocused = false }

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                Spacer(minLength: 12)

                VStack(spacing: 10) {
                    Text(headline)
                        .font(.system(size: 30, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .contentTransition(.opacity)
                    Text(subline)
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.inkSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(inputFocused ? 2 : 5)
                        .padding(.horizontal, 28)
                }
                .foregroundStyle(Theme.ink)
                .animation(.easeInOut(duration: 0.2), value: headline)

                Spacer(minLength: 12)

                OrbView(mood: mood)
                    .frame(width: inputFocused ? 110 : 220, height: inputFocused ? 110 : 220)
                    .contentShape(Circle())
                    .onTapGesture(perform: orbTapped)
                    .accessibilityLabel("Сфера")
                    .accessibilityHint(orbHint)
                    .animation(.spring(duration: 0.35), value: inputFocused)

                Spacer(minLength: 12)

                VStack(spacing: 12) {
                    if !glasses.isRegistered {
                        registrationCard
                    } else if !inputFocused {
                        topicCard
                    }
                    inputBar
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings, library: library)
        }
        .sheet(isPresented: $showLibrary) {
            LibraryView(assistant: assistant, library: library)
        }
        .sheet(item: $openTopic) { ref in
            NavigationStack {
                TopicChatView(topicId: ref.id, assistant: assistant, library: library, showsCloseButton: true)
            }
            .preferredColorScheme(.dark)
        }
        .alert("Ошибка", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("Ок", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    // MARK: Верхняя панель

    private var topBar: some View {
        HStack {
            GlassIconButton(systemName: "clock.arrow.circlepath") { showLibrary = true }
                .accessibilityLabel("История")
            Spacer()
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(Theme.deepBlue)
                    Image(systemName: "sparkle")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.ink)
                }
                .frame(width: 30, height: 30)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 1.5))

                Text("Гермес")
                    .font(.system(size: 17, weight: .semibold))

                HStack(spacing: 5) {
                    Circle().fill(chipColor).frame(width: 6, height: 6)
                    Text(chipText).font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .glass(radius: 12)
            }
            .foregroundStyle(Theme.ink)
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .glass(radius: 26)
            Spacer()
            GlassIconButton(systemName: "gearshape") { showSettings = true }
                .accessibilityLabel("Настройки")
        }
    }

    // MARK: Карточки

    private var registrationCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "eyeglasses")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .glass(radius: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text("Подключи очки")
                    .font(.system(size: 16, weight: .semibold))
                Text(glasses.registration == .registering ? "Жду подтверждения в Meta AI…" : "Подтверждение откроется в Meta AI")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkSecondary)
            }
            Spacer()
            Button("Подключить") { register() }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.deepBlue)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color.white))
                .buttonStyle(.plain)
        }
        .foregroundStyle(Theme.ink)
        .padding(12)
        .glass()
    }

    private var topicCard: some View {
        let topic = library.currentTopic
        return HStack(spacing: 12) {
            Image(systemName: topic == nil ? "plus.bubble" : "text.bubble.fill")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .glass(radius: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(topic?.title ?? "Новая тема")
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                Text(topicSubtitle(topic))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if topic != nil {
                Button {
                    library.startNewTopic()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Новая тема")
            }
        }
        .foregroundStyle(Theme.ink)
        .padding(12)
        .glass()
        .contentShape(Rectangle())
        .onTapGesture {
            if let id = topic?.id { openTopic = TopicRef(id: id) }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            Button(action: toggleVoice) {
                Image(systemName: assistant.isRunning ? "stop.fill" : "mic.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(assistant.isRunning ? Color.white : Theme.deepBlue)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(assistant.isRunning ? Color.red.opacity(0.85) : Color.white))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(assistant.isRunning ? "Остановить голос" : "Говорить через очки")

            HStack(spacing: 6) {
                TextField("", text: $draft, prompt: Text("Напиши… («Гермес, …» — поручение)").foregroundColor(Theme.inkTertiary))
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.ink)
                    .tint(Theme.ink)
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit(sendDraft)
                if canSend {
                    Button(action: sendDraft) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(Color.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Отправить")
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(minHeight: 52)
            .glass(radius: 26)
        }
    }

    // MARK: Действия

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !assistant.isBusy
    }

    private func sendDraft() {
        guard canSend else { return }
        let text = draft
        draft = ""
        inputFocused = false
        if let id = assistant.sendText(text) {
            openTopic = TopicRef(id: id)
        }
    }

    private func orbTapped() {
        inputFocused = false
        switch assistant.status {
        case .off, .error:
            startVoice()
        case .speaking:
            assistant.interrupt()
        case .listening:
            if settings.requireWakeWord { assistant.listenWithoutWakeWord() }
        case .starting, .thinking:
            break
        }
    }

    private func toggleVoice() {
        if assistant.isRunning {
            assistant.stop()
        } else {
            startVoice()
        }
    }

    private func startVoice() {
        guard glasses.isRegistered else {
            register()
            return
        }
        Task { await assistant.start() }
    }

    private func register() {
        Task {
            do { try await glasses.register() } catch { errorText = error.localizedDescription }
        }
    }

    // MARK: Тексты состояния

    private var mood: OrbMood {
        switch assistant.status {
        case .off: return .idle
        case .starting, .thinking: return .thinking
        case .listening: return .listening
        case .speaking: return .speaking
        case .error: return .error
        }
    }

    private var headline: String {
        switch assistant.status {
        case .off: return "Готов к разговору"
        case .starting: return "Подключаюсь…"
        case .listening: return "Слушаю"
        case .thinking: return "Думаю…"
        case .speaking: return "Отвечаю"
        case .error: return "Что-то пошло не так"
        }
    }

    private var subline: String {
        switch assistant.status {
        case .off:
            return glasses.isRegistered
                ? "Нажми на сферу, чтобы говорить через очки, или напиши сообщение"
                : "Подключи очки, а пока можно писать текстом"
        case .starting:
            return "Держи очки надетыми — это пара секунд"
        case .listening:
            if !voice.liveTranscript.isEmpty { return "«\(voice.liveTranscript)»" }
            if let hint = assistant.hint { return hint }
            return settings.requireWakeWord
                ? "Начни фразу с «Джипити…» или нажми на сферу"
                : "Говори — отвечу, когда сделаешь паузу"
        case .thinking:
            return assistant.lastQuestion
        case .speaking:
            return assistant.lastAnswer
        case .error(let message):
            return message
        }
    }

    private var orbHint: String {
        switch assistant.status {
        case .off, .error: return "Начать голосовой разговор"
        case .speaking: return "Прервать ответ"
        case .listening: return "Отправить следующую фразу без слова «Джипити»"
        default: return ""
        }
    }

    private var chipText: String {
        switch assistant.status {
        case .off: return assistant.isBusy ? "Думает" : "Готов"
        case .starting: return "Подключаюсь"
        case .listening: return "Слушает"
        case .thinking: return "Думает"
        case .speaking: return "Говорит"
        case .error: return "Ошибка"
        }
    }

    private var chipColor: Color {
        switch assistant.status {
        case .off: return Color.white.opacity(0.8)
        case .starting, .thinking: return Color.yellow
        case .listening, .speaking: return Color.green
        case .error: return Color.red
        }
    }

    private func topicSubtitle(_ topic: Topic?) -> String {
        guard let topic else { return "Следующий вопрос начнёт новую тему" }
        return "\(RU.messages(topic.messages.count)) · \(RU.relative(topic.updatedAt))"
    }
}
