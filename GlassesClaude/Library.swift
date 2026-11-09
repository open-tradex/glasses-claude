import Foundation

/// Одно сообщение в теме.
struct ChatMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case user, assistant }
    enum Source: String, Codable { case voice, text }

    var id = UUID()
    var role: Role
    var text: String
    var date = Date()
    var source: Source = .voice
    var isError = false
}

/// Тема = отдельный разговор со своей историей. Может лежать в папке.
struct Topic: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var titleIsManual = false
    var folderId: UUID?
    var createdAt = Date()
    var updatedAt = Date()
    var messages: [ChatMessage] = []
}

struct Folder: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var createdAt = Date()
}

/// Хранилище тем и папок. Всё лежит в одном JSON-файле на iPhone.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var topics: [Topic] = []
    @Published private(set) var folders: [Folder] = []
    /// Тема, в которую сейчас пишутся сообщения. nil — следующая фраза начнёт новую тему.
    @Published var currentTopicId: UUID? {
        didSet { save() }
    }

    private struct Snapshot: Codable {
        var topics: [Topic]
        var folders: [Folder]
        var currentTopicId: UUID?
    }

    private let url: URL
    private var saveTask: Task<Void, Never>?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("library.json")
        load()
    }

    // MARK: Чтение

    var currentTopic: Topic? {
        guard let id = currentTopicId else { return nil }
        return topics.first { $0.id == id }
    }

    func topic(_ id: UUID) -> Topic? {
        topics.first { $0.id == id }
    }

    func folder(_ id: UUID) -> Folder? {
        folders.first { $0.id == id }
    }

    var allTopics: [Topic] {
        topics.sorted { $0.updatedAt > $1.updatedAt }
    }

    func topics(inFolder folderId: UUID?) -> [Topic] {
        allTopics.filter { $0.folderId == folderId }
    }

    func search(_ query: String) -> [Topic] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return allTopics }
        return allTopics.filter { topic in
            topic.title.localizedCaseInsensitiveContains(q)
                || topic.messages.contains { $0.text.localizedCaseInsensitiveContains(q) }
        }
    }

    /// История текущей темы в формате API: роли чередуются, начинается с user, заканчивается assistant.
    func apiHistory(limit: Int = 20) -> [Brain.Turn] {
        guard let topic = currentTopic else { return [] }
        var merged: [Brain.Turn] = []
        for message in topic.messages where !message.isError {
            let role = message.role.rawValue
            if let last = merged.last, last.role == role {
                merged[merged.count - 1] = .init(role: role, text: last.text + "\n" + message.text)
            } else {
                merged.append(.init(role: role, text: message.text))
            }
        }
        var result = Array(merged.suffix(limit))
        while result.first?.role == "assistant" { result.removeFirst() }
        while result.last?.role == "user" { result.removeLast() }
        return result
    }

    // MARK: Темы

    func startNewTopic() {
        currentTopicId = nil
    }

    /// Если в текущей теме давно не было сообщений — следующая фраза начнёт новую тему.
    func splitIfIdle(after interval: TimeInterval) {
        if let topic = currentTopic, Date().timeIntervalSince(topic.updatedAt) > interval {
            currentTopicId = nil
        }
    }

    /// Добавляет сообщение в текущую тему (или создаёт новую). Возвращает id темы.
    @discardableResult
    func appendToCurrent(_ message: ChatMessage) -> UUID {
        if let id = currentTopicId, let index = topics.firstIndex(where: { $0.id == id }) {
            topics[index].messages.append(message)
            topics[index].updatedAt = Date()
            save()
            return id
        }
        var topic = Topic(title: Self.makeTitle(message.text))
        topic.messages.append(message)
        topics.insert(topic, at: 0)
        currentTopicId = topic.id
        save()
        return topic.id
    }

    /// Добавляет сообщение в конкретную тему (например, ответ модели). Если тему удалили — ничего не делает.
    func append(_ message: ChatMessage, to topicId: UUID) {
        guard let index = topics.firstIndex(where: { $0.id == topicId }) else { return }
        topics[index].messages.append(message)
        topics[index].updatedAt = Date()
        save()
    }

    func renameTopic(_ id: UUID, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = topics.firstIndex(where: { $0.id == id }) else { return }
        topics[index].title = clean
        topics[index].titleIsManual = true
        save()
    }

    /// Название, которое придумала модель. Не перезаписывает название, данное вручную.
    func setAutoTitle(_ id: UUID, _ title: String) {
        let clean = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"«».!"))
        guard !clean.isEmpty, clean.count <= 60,
              let index = topics.firstIndex(where: { $0.id == id }),
              !topics[index].titleIsManual else { return }
        topics[index].title = clean
        save()
    }

    func moveTopic(_ id: UUID, to folderId: UUID?) {
        guard let index = topics.firstIndex(where: { $0.id == id }) else { return }
        topics[index].folderId = folderId
        save()
    }

    func deleteTopic(_ id: UUID) {
        topics.removeAll { $0.id == id }
        if currentTopicId == id { currentTopicId = nil }
        save()
    }

    func deleteEverything() {
        topics.removeAll()
        folders.removeAll()
        currentTopicId = nil
        save()
    }

    // MARK: Папки

    @discardableResult
    func createFolder(_ name: String) -> Folder? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let folder = Folder(name: clean)
        folders.append(folder)
        save()
        return folder
    }

    func renameFolder(_ id: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = clean
        save()
    }

    /// Удаляет папку. Темы из неё не удаляются, а переезжают в «Без папки».
    func deleteFolder(_ id: UUID) {
        folders.removeAll { $0.id == id }
        for index in topics.indices where topics[index].folderId == id {
            topics[index].folderId = nil
        }
        save()
    }

    func topicCount(inFolder id: UUID) -> Int {
        topics.filter { $0.folderId == id }.count
    }

    // MARK: Сохранение

    static func makeTitle(_ text: String) -> String {
        let clean = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "Новая тема" }
        let short = clean.count > 40
            ? String(clean.prefix(40)).trimmingCharacters(in: .whitespaces) + "…"
            : clean
        return short.prefix(1).uppercased() + short.dropFirst()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        topics = snapshot.topics
        folders = snapshot.folders
        currentTopicId = snapshot.currentTopicId
    }

    private func save() {
        saveTask?.cancel()
        let snapshot = Snapshot(topics: topics, folders: folders, currentTopicId: currentTopicId)
        let url = self.url
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
