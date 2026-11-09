import Foundation
import Security

/// Когда прикладывать кадр с камеры очков к вопросу.
enum ImageMode: String, CaseIterable, Identifiable {
    case auto, always, never
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Авто (по словам «посмотри», «что это»…)"
        case .always: return "Всегда"
        case .never: return "Никогда"
        }
    }
}

/// Настройки приложения. Токен шлюза хранится в Keychain, остальное — в UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    static let defaultGateway = Brain.defaultURL

    /// Адрес шлюза glasses-gw (доступен только внутри Tailscale).
    @Published var gatewayURL: String {
        didSet { UserDefaults.standard.set(gatewayURL, forKey: "gatewayURL") }
    }
    @Published var gatewayToken: String {
        didSet { Keychain.save(gatewayToken, for: "gateway_token") }
    }
    @Published var imageMode: ImageMode {
        didSet { UserDefaults.standard.set(imageMode.rawValue, forKey: "imageMode") }
    }
    /// Камера очков. Если поток не поднимется, голос всё равно работает.
    @Published var cameraOn: Bool {
        didSet { UserDefaults.standard.set(cameraOn, forKey: "cameraOn") }
    }
    /// Отвечать только на фразы с «Джипити …». По умолчанию выключено — отвечает на любую фразу.
    @Published var requireWakeWord: Bool {
        didSet { UserDefaults.standard.set(requireWakeWord, forKey: "requireWakeWord.v2") }
    }
    /// true — микрофоны очков (Bluetooth HFP, 8 кГц); false — микрофон iPhone, звук ответа в очках чище.
    @Published var useGlassesMic: Bool {
        didSet { UserDefaults.standard.set(useGlassesMic, forKey: "useGlassesMic") }
    }
    /// Скорость речи ответа, 0.4…0.6 — комфортный диапазон.
    @Published var speechRate: Double {
        didSet { UserDefaults.standard.set(speechRate, forKey: "speechRate") }
    }

    var brain: Brain { Brain(baseURL: gatewayURL, token: gatewayToken) }

    private init() {
        let d = UserDefaults.standard
        gatewayURL = d.string(forKey: "gatewayURL") ?? AppSettings.defaultGateway
        gatewayToken = Keychain.load("gateway_token") ?? ""
        imageMode = ImageMode(rawValue: d.string(forKey: "imageMode") ?? "") ?? .auto
        cameraOn = d.object(forKey: "cameraOn") as? Bool ?? true
        requireWakeWord = d.object(forKey: "requireWakeWord.v2") as? Bool ?? false
        speechRate = d.object(forKey: "speechRate") as? Double ?? 0.52
        useGlassesMic = d.object(forKey: "useGlassesMic") as? Bool ?? true
    }
}

enum Keychain {
    static func save(_ value: String, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: key,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
