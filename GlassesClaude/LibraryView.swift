import SwiftUI

struct FolderRoute: Hashable {
    let id: UUID
}

// MARK: Действия над темой (переименовать / переместить / удалить)

@MainActor
final class TopicActions: ObservableObject {
    @Published var renameTarget: UUID?
    @Published var renameText = ""
    @Published var moveTarget: UUID?
    @Published var deleteTarget: UUID?

    func rename(_ topic: Topic) {
        renameText = topic.title
        renameTarget = topic.id
    }
}

struct TopicActionDialogs: ViewModifier {
    @ObservedObject var actions: TopicActions
    @ObservedObject var library: LibraryStore
    var onDeleted: ((UUID) -> Void)?

    func body(content: Content) -> some View {
        content
            .alert("Название темы", isPresented: Binding(
                get: { actions.renameTarget != nil },
                set: { if !$0 { actions.renameTarget = nil } }
            )) {
                TextField("Название", text: $actions.renameText)
                Button("Сохранить") {
                    if let id = actions.renameTarget { library.renameTopic(id, to: actions.renameText) }
                    actions.renameTarget = nil
                }
                Button("Отмена", role: .cancel) { actions.renameTarget = nil }
            }
            .confirmationDialog("Переместить в папку", isPresented: Binding(
                get: { actions.moveTarget != nil },
                set: { if !$0 { actions.moveTarget = nil } }
            ), titleVisibility: .visible) {
                Button("Без папки") { move(to: nil) }
                ForEach(library.folders) { folder in
                    Button(folder.name) { move(to: folder.id) }
                }
                Button("Отмена", role: .cancel) { actions.moveTarget = nil }
            } message: {
                if library.folders.isEmpty {
                    Text("Папок пока нет — создай её в истории.")
                }
            }
            .confirmationDialog("Удалить тему?", isPresented: Binding(
                get: { actions.deleteTarget != nil },
                set: { if !$0 { actions.deleteTarget = nil } }
            ), titleVisibility: .visible) {
                Button("Удалить", role: .destructive) {
                    if let id = actions.deleteTarget {
                        library.deleteTopic(id)
                        onDeleted?(id)
                    }
                    actions.deleteTarget = nil
                }
                Button("Отмена", role: .cancel) { actions.deleteTarget = nil }
            } message: {
                Text("Все сообщения темы удалятся.")
            }
    }

    private func move(to folderId: UUID?) {
        if let id = actions.moveTarget { library.moveTopic(id, to: folderId) }
        actions.moveTarget = nil
    }
}

extension View {
    func topicActionDialogs(_ actions: TopicActions, library: LibraryStore, onDeleted: ((UUID) -> Void)? = nil) -> some View {
        modifier(TopicActionDialogs(actions: actions, library: library, onDeleted: onDeleted))
    }

    /// Прозрачный список поверх нашего градиента.
    func glassList() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .toolbarBackground(.hidden, for: .navigationBar)
    }
}

// MARK: Строка темы

struct TopicRow: View {
    let topic: Topic
    let isCurrent: Bool
    var folderName: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isCurrent ? "waveform" : "text.bubble")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.white.opacity(isCurrent ? 0.35 : 0.18)))
            VStack(alignment: .leading, spacing: 3) {
                Text(topic.title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                Text(preview)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(2)
                if let folderName {
                    Label(folderName, systemImage: "folder")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
            Spacer(minLength: 8)
            Text(RU.relative(topic.updatedAt))
                .font(.system(size: 11))
                .foregroundStyle(Theme.inkTertiary)
        }
        .foregroundStyle(Theme.ink)
        .padding(.vertical, 4)
    }

    private var preview: String {
        guard let last = topic.messages.last else { return "Пусто" }
        return (last.role == .user ? "Ты: " : "") + last.text
    }
}

/// Свайпы и контекстное меню для строки темы.
struct TopicRowActions: ViewModifier {
    let topic: Topic
    @ObservedObject var actions: TopicActions

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button { actions.deleteTarget = topic.id } label: {
                    Label("Удалить", systemImage: "trash")
                }
                .tint(.red)
                Button { actions.moveTarget = topic.id } label: {
                    Label("В папку", systemImage: "folder")
                }
                .tint(.indigo)
            }
            .swipeActions(edge: .leading) {
                Button { actions.rename(topic) } label: {
                    Label("Переименовать", systemImage: "pencil")
                }
                .tint(.blue)
            }
            .contextMenu {
                Button { actions.rename(topic) } label: { Label("Переименовать", systemImage: "pencil") }
                Button { actions.moveTarget = topic.id } label: { Label("Переместить в папку", systemImage: "folder") }
                Button(role: .destructive) { actions.deleteTarget = topic.id } label: { Label("Удалить", systemImage: "trash") }
            }
    }
}

// MARK: История

struct LibraryView: View {
    @ObservedObject var assistant: Assistant
    @ObservedObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var actions = TopicActions()
    @State private var search = ""
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if search.isEmpty {
                    Section {
                        ForEach(library.folders) { folder in
                            NavigationLink(value: FolderRoute(id: folder.id)) {
                                HStack(spacing: 12) {
                                    Image(systemName: "folder.fill")
                                        .font(.system(size: 15, weight: .semibold))
                                        .frame(width: 38, height: 38)
                                        .background(Circle().fill(Color.white.opacity(0.18)))
                                    Text(folder.name)
                                        .font(.system(size: 16, weight: .semibold))
                                    Spacer()
                                    Text(RU.topics(library.topicCount(inFolder: folder.id)))
                                        .font(.system(size: 13))
                                        .foregroundStyle(Theme.inkSecondary)
                                }
                                .foregroundStyle(Theme.ink)
                            }
                            .listRowBackground(Theme.glassFill)
                        }
                        Button {
                            newFolderName = ""
                            showNewFolder = true
                        } label: {
                            Label("Новая папка", systemImage: "folder.badge.plus")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                        }
                        .listRowBackground(Theme.glassFill)
                    } header: {
                        sectionHeader("Папки")
                    }
                }

                Section {
                    if visibleTopics.isEmpty {
                        Text(search.isEmpty ? "Тем пока нет. Задай первый вопрос голосом или текстом." : "Ничего не нашлось")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.inkSecondary)
                            .listRowBackground(Theme.glassFill)
                    }
                    ForEach(visibleTopics) { topic in
                        NavigationLink(value: TopicRef(id: topic.id)) {
                            TopicRow(
                                topic: topic,
                                isCurrent: topic.id == library.currentTopicId,
                                folderName: topic.folderId.flatMap { library.folder($0)?.name }
                            )
                        }
                        .listRowBackground(Theme.glassFill)
                        .modifier(TopicRowActions(topic: topic, actions: actions))
                    }
                } header: {
                    sectionHeader(search.isEmpty ? "Все темы" : "Найдено")
                }
            }
            .glassList()
            .searchable(text: $search, prompt: "Поиск по темам и сообщениям")
            .navigationTitle("История")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Готово") { dismiss() }
                        .foregroundStyle(Theme.ink)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            library.startNewTopic()
                            dismiss()
                        } label: { Label("Новая тема", systemImage: "square.and.pencil") }
                        Button {
                            newFolderName = ""
                            showNewFolder = true
                        } label: { Label("Новая папка", systemImage: "folder.badge.plus") }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                    }
                }
            }
            .navigationDestination(for: FolderRoute.self) { route in
                FolderView(folderId: route.id, assistant: assistant, library: library, onContinue: { dismiss() })
            }
            .navigationDestination(for: TopicRef.self) { ref in
                TopicChatView(topicId: ref.id, assistant: assistant, library: library, onContinue: { dismiss() })
            }
            .topicActionDialogs(actions, library: library)
            .alert("Новая папка", isPresented: $showNewFolder) {
                TextField("Например, «Работа»", text: $newFolderName)
                Button("Создать") { library.createFolder(newFolderName) }
                Button("Отмена", role: .cancel) {}
            }
        }
        .preferredColorScheme(.dark)
    }

    private var visibleTopics: [Topic] {
        library.search(search)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.inkSecondary)
            .textCase(nil)
    }
}

// MARK: Папка

struct FolderView: View {
    let folderId: UUID
    @ObservedObject var assistant: Assistant
    @ObservedObject var library: LibraryStore
    var onContinue: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    @StateObject private var actions = TopicActions()
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDelete = false

    var body: some View {
        List {
            let topics = library.topics(inFolder: folderId)
            if topics.isEmpty {
                Text("В папке пока пусто. Перемести сюда тему: свайп влево по теме → «В папку».")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.inkSecondary)
                    .listRowBackground(Theme.glassFill)
            }
            ForEach(topics) { topic in
                NavigationLink(value: TopicRef(id: topic.id)) {
                    TopicRow(topic: topic, isCurrent: topic.id == library.currentTopicId)
                }
                .listRowBackground(Theme.glassFill)
                .modifier(TopicRowActions(topic: topic, actions: actions))
            }
        }
        .glassList()
        .navigationTitle(library.folder(folderId)?.name ?? "Папка")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        renameText = library.folder(folderId)?.name ?? ""
                        showRename = true
                    } label: { Label("Переименовать", systemImage: "pencil") }
                    Button(role: .destructive) { showDelete = true } label: {
                        Label("Удалить папку", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Theme.ink)
                }
            }
        }
        .topicActionDialogs(actions, library: library)
        .alert("Название папки", isPresented: $showRename) {
            TextField("Название", text: $renameText)
            Button("Сохранить") { library.renameFolder(folderId, to: renameText) }
            Button("Отмена", role: .cancel) {}
        }
        .confirmationDialog("Удалить папку?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Удалить папку", role: .destructive) {
                library.deleteFolder(folderId)
                dismiss()
            }
        } message: {
            Text("Темы не удалятся — они переедут в «Все темы».")
        }
    }
}

// MARK: Переписка в теме

struct TopicChatView: View {
    let topicId: UUID
    @ObservedObject var assistant: Assistant
    @ObservedObject var library: LibraryStore
    var showsCloseButton = false
    var onContinue: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    @StateObject private var actions = TopicActions()
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        ZStack {
            AppBackground()
            if let topic = library.topic(topicId) {
                VStack(spacing: 0) {
                    messages(topic)
                    inputBar
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
            } else {
                Text("Тема удалена")
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .navigationTitle(library.topic(topicId)?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Закрыть") { dismiss() }
                        .foregroundStyle(Theme.ink)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        library.currentTopicId = topicId
                        if let onContinue { onContinue() } else { dismiss() }
                    } label: { Label("Продолжить голосом", systemImage: "waveform") }
                    if let topic = library.topic(topicId) {
                        Button { actions.rename(topic) } label: { Label("Переименовать", systemImage: "pencil") }
                    }
                    Button { actions.moveTarget = topicId } label: { Label("Переместить в папку", systemImage: "folder") }
                    Button(role: .destructive) { actions.deleteTarget = topicId } label: {
                        Label("Удалить тему", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Theme.ink)
                }
            }
        }
        .topicActionDialogs(actions, library: library, onDeleted: { _ in dismiss() })
    }

    private var isTyping: Bool {
        assistant.isBusy && library.currentTopicId == topicId
    }

    private func messages(_ topic: Topic) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(topic.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if isTyping {
                        TypingBubble().id("typing")
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear { scrollToBottom(proxy, topic: topic, animated: false) }
            .onChange(of: topic.messages.count) { _, _ in scrollToBottom(proxy, topic: topic, animated: true) }
            .onChange(of: isTyping) { _, _ in scrollToBottom(proxy, topic: topic, animated: true) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, topic: Topic, animated: Bool) {
        let target: AnyHashable
        if isTyping {
            target = AnyHashable("typing")
        } else if let last = topic.messages.last {
            target = AnyHashable(last.id)
        } else {
            return
        }
        if animated {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(target, anchor: .bottom) }
        } else {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !assistant.isBusy
    }

    private var inputBar: some View {
        HStack(spacing: 6) {
            TextField("", text: $draft, prompt: Text("Сообщение в эту тему…").foregroundColor(Theme.inkTertiary))
                .font(.system(size: 16))
                .foregroundStyle(Theme.ink)
                .tint(Theme.ink)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.white.opacity(canSend ? 1 : 0.35))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Отправить")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(minHeight: 52)
        .glass(radius: 26)
    }

    private func send() {
        guard canSend else { return }
        let text = draft
        draft = ""
        assistant.sendText(text, inTopic: topicId)
    }
}

// MARK: Пузыри сообщений

struct MessageBubble: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 48) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 5) {
                Text(message.text)
                    .font(.system(size: 16))
                    .foregroundStyle(isUser ? Theme.deepBlue : Theme.ink)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    Image(systemName: message.source == .voice ? "mic.fill" : "keyboard")
                    Text(RU.time(message.date))
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isUser ? Theme.deepBlue.opacity(0.6) : Theme.inkTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(bubble)
            if !isUser { Spacer(minLength: 48) }
        }
    }

    @ViewBuilder private var bubble: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        if isUser {
            shape.fill(Color.white)
        } else if message.isError {
            shape.fill(Color.red.opacity(0.35))
                .overlay(shape.strokeBorder(Color.red.opacity(0.6), lineWidth: 1))
        } else {
            shape.fill(Theme.glassFill)
                .overlay(shape.strokeBorder(Theme.glassStroke, lineWidth: 1))
        }
    }
}

struct TypingBubble: View {
    var body: some View {
        HStack {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(Color.white)
                            .frame(width: 7, height: 7)
                            .opacity(0.35 + 0.65 * max(0, sin(t * 5 - Double(i) * 0.7)))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .glass(radius: 20)
            Spacer()
        }
        .accessibilityLabel("Печатает")
    }
}
