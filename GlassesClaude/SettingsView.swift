import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmWipe = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://100.x.x.x:8650", text: $settings.gatewayURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Токен", text: $settings.gatewayToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Шлюз Hermes")
                } footer: {
                    Text("Работает только при включённом Tailscale на iPhone. Токен хранится в Keychain.")
                }

                Section {
                    Toggle("Отвечать только на «Джипити, …»", isOn: $settings.requireWakeWord)
                } header: {
                    Text("Голос")
                } footer: {
                    Text((settings.requireWakeWord
                         ? "Отвечаю только на фразы со словом «Джипити». Тап по сфере — отправить следующую фразу без него."
                         : "Отвечаю на любую фразу после паузы. Удобно в тишине, но могу реагировать на чужую речь.")
                         + "\n«Гермес, …» — поручение агенту Hermes, «Иберика, …» — боту Иберики. Ответ придёт голосом и в Telegram.")
                }

                Section {
                    Toggle("Слушать микрофонами очков", isOn: $settings.useGlassesMic)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Скорость речи")
                        Slider(value: $settings.speechRate, in: 0.4...0.6)
                    }
                } footer: {
                    Text("Если выключить микрофоны очков, слушаю через iPhone, а голос ответа в очках звучит чище. После изменения перезапусти голос.")
                }

                Section {
                    Toggle("Камера очков", isOn: $settings.cameraOn)
                    if settings.cameraOn {
                        Picker("Кадр", selection: $settings.imageMode) {
                            ForEach(ImageMode.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                } header: {
                    Text("Кадр с камеры очков")
                } footer: {
                    Text("После изменения перезапусти голос.")
                }

                Section {
                    Button("Начать новую тему") {
                        library.startNewTopic()
                        dismiss()
                    }
                    Button("Удалить всю историю и папки", role: .destructive) {
                        confirmWipe = true
                    }
                } header: {
                    Text("История")
                } footer: {
                    Text("\(RU.topics(library.topics.count)), папок: \(library.folders.count). Если 30 минут не общаться, новая тема начнётся сама.")
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .confirmationDialog("Удалить всю историю?", isPresented: $confirmWipe, titleVisibility: .visible) {
                Button("Удалить всё", role: .destructive) { library.deleteEverything() }
            } message: {
                Text("Все темы, сообщения и папки удалятся с iPhone без возможности восстановления.")
            }
        }
        .preferredColorScheme(.dark)
    }
}
