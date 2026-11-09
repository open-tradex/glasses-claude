import Foundation
import UIKit

/// Клиент нашего шлюза glasses-gw на VPS (Tailscale): быстрый GPT и поручения агентам Hermes.
struct Brain {
    struct Turn {
        let role: String   // "user" | "assistant"
        let text: String
    }

    /// Кому поручение: агент Hermes или бот Иберики.
    enum Agent: String {
        case hermes, iberika
        var title: String { self == .hermes ? "Гермес" : "Иберика" }
    }

    enum ClientError: LocalizedError {
        case noToken
        case http(Int, String)
        case empty

        var errorDescription: String? {
            switch self {
            case .noToken:
                return "Не указан токен шлюза — вставь его в настройках."
            case .http(let code, let body):
                switch code {
                case 401: return "Токен шлюза не подходит (401). Вставь его заново в настройках."
                case 0: return "Сервер недоступен. Проверь, что на iPhone включён Tailscale."
                default: return "Ошибка шлюза \(code): \(body.prefix(200))"
                }
            case .empty:
                return "Пустой ответ."
            }
        }
    }

    let baseURL: String
    let token: String

    /// Быстрый вопрос GPT (с историей и, при необходимости, кадром).
    func send(history: [Turn], userText: String, image: UIImage?) async throws -> String {
        var body: [String: Any] = [
            "text": userText,
            "history": history.map { ["role": $0.role, "text": $0.text] },
        ]
        if let image, let b64 = image.base64JPEG() { body["image"] = b64 }
        let json = try await post("/chat", body, timeout: 60)
        guard let reply = json["reply"] as? String, !reply.isEmpty else { throw ClientError.empty }
        return reply
    }

    /// Короткое название темы по первому вопросу и ответу.
    func topicTitle(question: String, answer: String) async throws -> String {
        let body: [String: Any] = [
            "text": "Вопрос: \(question)\nОтвет: \(answer.prefix(400))",
            "instructions": "Придумай короткое название для этого разговора: 2–4 слова по-русски, с заглавной буквы, без кавычек и точки в конце. Ответь только названием.",
        ]
        let json = try await post("/chat", body, timeout: 30)
        guard let reply = json["reply"] as? String, !reply.isEmpty else { throw ClientError.empty }
        return reply
    }

    /// Поручение агенту. Возвращает (id задачи, короткое «принял»).
    func startAgent(_ agent: Agent, text: String, image: UIImage?) async throws -> (String, String) {
        var body: [String: Any] = ["target": agent.rawValue, "text": text]
        if let image, let b64 = image.base64JPEG() { body["image"] = b64 }
        let json = try await post("/agent", body, timeout: 30)
        guard let id = json["id"] as? String else { throw ClientError.empty }
        return (id, json["ack"] as? String ?? "\(agent.title) принял.")
    }

    /// Ждёт результат поручения (агент может работать минутами).
    func waitAgent(id: String, maxWait: TimeInterval = 1800) async throws -> String {
        let deadline = Date().addingTimeInterval(maxWait)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 4_000_000_000)
            let json = try await get("/agent/\(id)")
            if (json["status"] as? String) != "running" {
                return json["reply"] as? String ?? "Готово."
            }
        }
        return "Задача ещё идёт, результат придёт в Telegram."
    }

    // MARK: HTTP

    private func request(_ path: String, method: String, timeout: TimeInterval) throws -> URLRequest {
        guard !token.isEmpty else { throw ClientError.noToken }
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + path) else { throw ClientError.http(0, "плохой адрес") }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = timeout
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return r
    }

    private func post(_ path: String, _ body: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        var r = try request(path, method: "POST", timeout: timeout)
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await run(r)
    }

    private func get(_ path: String) async throws -> [String: Any] {
        try await run(try request(path, method: "GET", timeout: 20))
    }

    private func run(_ r: URLRequest) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: r)
        } catch {
            throw ClientError.http(0, error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            throw ClientError.http(status, json["error"] as? String ?? String(data: data, encoding: .utf8) ?? "")
        }
        return json
    }
}

extension UIImage {
    /// Ужимает до 1280 px по длинной стороне — хватает модели и экономит трафик.
    func resizedForUpload(maxSide: CGFloat = 1280) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return self }
        let scale = maxSide / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }

    func base64JPEG() -> String? {
        resizedForUpload().jpegData(compressionQuality: 0.8)?.base64EncodedString()
    }
}
