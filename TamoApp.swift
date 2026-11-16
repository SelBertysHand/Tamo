import SwiftUI
import Security
import UserNotifications
import Speech
import AVFoundation

// MARK: - Keychain (ключ OpenAI хранится в защищённом хранилище iOS)
enum Keychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrAccount as String: "openai-key"
    ]
    static func save(_ value: String) {
        SecItemDelete(base as CFDictionary)
        var q = base
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
    static func load() -> String {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return "" }
        return String(decoding: d, as: UTF8.self)
    }
}

// MARK: - Модели
struct Pet: Codable {
    var name = "Тамо"
    var species = "🐱"
    var hue = 0.72
    var accessory = ""
    var hunger = 0.8
    var energy = 0.8
    var mood = 0.8
    var coins = 0
    var owned = [""]
    var updated = Date()

    var status: String {
        if hunger < 0.25 { return "Хочу есть 🍖" }
        if energy < 0.25 { return "Хочу спать 💤" }
        if mood < 0.25 { return "Мне грустно, поиграй со мной" }
        return "Всё хорошо!"
    }
}
struct TaskItem: Identifiable, Codable { var id = UUID(); var title: String; var done = false }
struct Msg: Identifiable, Codable { var id = UUID(); var role: String; var text: String }

func loadJSON<T: Decodable>(_ key: String) -> T? {
    UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
}
func saveJSON<T: Encodable>(_ key: String, _ value: T) {
    if let d = try? JSONEncoder().encode(value) { UserDefaults.standard.set(d, forKey: key) }
}
func clamp(_ x: Double) -> Double { min(1, max(0, x)) }

// MARK: - Хранилище
@MainActor
final class Store: ObservableObject {
    @Published var pet: Pet { didSet { saveJSON("pet", pet) } }
    @Published var tasks: [TaskItem] { didSet { saveJSON("tasks", tasks) } }
    @Published var chat: [Msg] { didSet { saveJSON("chat", chat) } }
    @Published var loading = false
    @AppStorage("model") var model = "gpt-4o-mini"

    init() {
        pet = loadJSON("pet") ?? Pet()
        tasks = loadJSON("tasks") ?? []
        chat = loadJSON("chat") ?? []
        tick()
    }

    /// Питомец голодает и устаёт, пока вас нет
    func tick() {
        let h = Date().timeIntervalSince(pet.updated) / 3600
        pet.hunger = clamp(pet.hunger - 0.06 * h)
        pet.energy = clamp(pet.energy - 0.03 * h)
        let extra = pet.hunger < 0.2 ? 0.02 * h : 0
        pet.mood = clamp(pet.mood - 0.04 * h - extra)
        pet.updated = Date()
    }
    func feed() { pet.hunger = clamp(pet.hunger + 0.3); pet.mood = clamp(pet.mood + 0.05) }
    func play() { pet.mood = clamp(pet.mood + 0.3); pet.energy = clamp(pet.energy - 0.1) }
    func sleep() { pet.energy = clamp(pet.energy + 0.4) }

    func askNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    /// Напоминание, если вы не заходили 6 часов
    func scheduleHungerNotice() {
        let c = UNUserNotificationCenter.current()
        c.removeAllPendingNotificationRequests()
        let content = UNMutableNotificationContent()
        content.title = pet.name
        content.body = "Я проголодался! Загляни ко мне 🍖"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 6 * 3600, repeats: false)
        c.add(UNNotificationRequest(identifier: "hungry", content: content, trigger: trigger))
    }

    func send(_ text: String) async {
        chat.append(Msg(role: "user", text: text))
        loading = true
        defer { loading = false }
        let key = Keychain.load()
        guard !key.isEmpty else {
            chat.append(Msg(role: "assistant", text: "Добавь ключ OpenAI во вкладке «Вид», и я смогу отвечать."))
            return
        }
        let open = tasks.filter { !$0.done }.map { $0.title }.joined(separator: ", ")
        let sys = "Ты — виртуальный питомец-помощник по имени \(pet.name) (\(pet.species)). Отвечай коротко, тепло и по делу, на языке пользователя. Состояние: сытость \(Int(pet.hunger * 100))%, энергия \(Int(pet.energy * 100))%, настроение \(Int(pet.mood * 100))%. Невыполненные дела пользователя: \(open.isEmpty ? "нет" : open)."
        var messages: [[String: String]] = [["role": "system", "content": sys]]
        messages += chat.suffix(12).map { ["role": $0.role, "content": $0.text] }
        let body: [String: Any] = ["model": model, "messages": messages]

        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let choice = (json?["choices"] as? [[String: Any]])?.first,
               let message = choice["message"] as? [String: Any],
               let reply = message["content"] as? String {
                chat.append(Msg(role: "assistant", text: reply))
                pet.mood = clamp(pet.mood + 0.03)
            } else if let err = (json?["error"] as? [String: Any])?["message"] as? String {
                chat.append(Msg(role: "assistant", text: "Ошибка: \(err)"))
            }
        } catch {
            chat.append(Msg(role: "assistant", text: "Нет связи: \(error.localizedDescription)"))
        }
    }
}

// MARK: - Приложение
@main
struct TamoApp: App {
    @StateObject private var store = Store()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            TabView {
                PetView().tabItem { Label("Питомец", systemImage: "pawprint.fill") }
                ChatView().tabItem { Label("Чат", systemImage: "bubble.left.and.bubble.right.fill") }
                TasksView().tabItem { Label("Дела", systemImage: "checklist") }
                FocusView().tabItem { Label("Фокус", systemImage: "timer") }
                StyleView().tabItem { Label("Вид", systemImage: "paintpalette.fill") }
            }
            .environmentObject(store)
            .onAppear { store.askNotifications() }
            .onChange(of: phase) { p in
                if p == .active { store.tick() }
                if p == .background { store.scheduleHungerNotice() }
            }
        }
    }
}

// MARK: - Питомец
struct PetView: View {
    @EnvironmentObject var s: Store
    @State private var bounce = false
    @State private var showGame = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("🪙 \(s.pet.coins)").font(.headline).frame(maxWidth: .infinity, alignment: .trailing)
                ZStack {
                    Circle().fill(Color(hue: s.pet.hue, saturation: 0.45, brightness: 0.95))
                        .frame(width: 230, height: 230)
                    Text(s.pet.species).font(.system(size: 120))
                    Text(s.pet.accessory).font(.system(size: 54)).offset(y: -100)
                }
                .offset(y: bounce ? -8 : 0)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { bounce = true }
                }
                Text(s.pet.name).font(.title.bold())
                Text(s.pet.status).foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    stat("Сытость", s.pet.hunger, .orange)
                    stat("Энергия", s.pet.energy, .blue)
                    stat("Настроение", s.pet.mood, .pink)
                }
                HStack {
                    Button { s.feed() } label: { Label("Кормить", systemImage: "fork.knife") }
                    Button { s.play() } label: { Label("Играть", systemImage: "gamecontroller") }
                    Button { s.sleep() } label: { Label("Спать", systemImage: "moon.zzz") }
                }
                .buttonStyle(.borderedProminent)
                .labelStyle(.titleAndIcon)
                .font(.footnote)
                Button("⭐️ Мини-игра: поймай звезду") { showGame = true }
                    .buttonStyle(.bordered)
            }
            .padding()
        }
        .sheet(isPresented: $showGame) { GameView() }
    }
    func stat(_ title: String, _ v: Double, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ProgressView(value: v).tint(c)
        }
    }
}

// MARK: - Чат с ChatGPT
struct ChatView: View {
    @EnvironmentObject var s: Store
    @State private var text = ""
    @StateObject private var dict = Dictation()

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(s.chat) { m in
                            Text(m.text)
                                .padding(10)
                                .background(m.role == "user" ? Color.accentColor : Color(.secondarySystemBackground))
                                .foregroundColor(m.role == "user" ? .white : .primary)
                                .cornerRadius(14)
                                .frame(maxWidth: .infinity, alignment: m.role == "user" ? .trailing : .leading)
                                .id(m.id)
                        }
                        if s.loading { ProgressView().frame(maxWidth: .infinity, alignment: .leading) }
                    }
                    .padding()
                }
                .onChange(of: s.chat.count) { _ in
                    if let last = s.chat.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            HStack {
                TextField("Спроси \(s.pet.name)…", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onChange(of: dict.text) { text = $0 }
                Button { dict.toggle() } label: {
                    Image(systemName: dict.listening ? "mic.fill" : "mic").font(.title2)
                }
                Button {
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    text = ""
                    Task { await s.send(t) }
                } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                .disabled(s.loading)
            }
            .padding()
        }
    }
}

// MARK: - Дела
struct TasksView: View {
    @EnvironmentObject var s: Store
    @State private var title = ""

    var body: some View {
        NavigationStack {
            List {
                HStack {
                    TextField("Новое дело", text: $title).onSubmit(add)
                    Button("Добавить", action: add).disabled(title.isEmpty)
                }
                ForEach($s.tasks) { $t in
                    Button {
                        t.done.toggle()
                        if t.done { s.pet.coins += 5; s.pet.mood = clamp(s.pet.mood + 0.05) }
                    } label: {
                        Label(t.title, systemImage: t.done ? "checkmark.circle.fill" : "circle")
                            .strikethrough(t.done)
                            .foregroundColor(t.done ? .secondary : .primary)
                    }
                }
                .onDelete { s.tasks.remove(atOffsets: $0) }
            }
            .navigationTitle("Дела")
            .toolbar { EditButton() }
        }
    }
    func add() {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        s.tasks.append(TaskItem(title: t))
        title = ""
    }
}

// MARK: - Фокус-таймер
struct FocusView: View {
    @EnvironmentObject var s: Store
    @State private var minutes = 25
    @State private var left = 25 * 60
    @State private var running = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 24) {
            Text(String(format: "%02d:%02d", left / 60, left % 60))
                .font(.system(size: 72, weight: .bold, design: .rounded)).monospacedDigit()
            Picker("Минуты", selection: $minutes) {
                ForEach([15, 25, 45], id: \.self) { Text("\($0) мин").tag($0) }
            }
            .pickerStyle(.segmented).disabled(running)
            .onChange(of: minutes) { left = $0 * 60 }
            Button(running ? "Сдаться" : "Начать") {
                if running { running = false; left = minutes * 60 } else { running = true }
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            Text("За каждую минуту фокуса \(s.pet.name) получает 🪙")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
        .onReceive(timer) { _ in
            guard running else { return }
            left -= 1
            if left <= 0 {
                running = false
                s.pet.coins += minutes
                s.pet.mood = clamp(s.pet.mood + 0.1)
                left = minutes * 60
            }
        }
    }
}

// MARK: - Кастомизация и настройки
struct StyleView: View {
    @EnvironmentObject var s: Store
    @State private var key = ""
    private let species = ["🐱", "🐶", "🐰", "🦊", "🐼", "🐸", "🐧", "🐙"]
    private let prices: [(String, Int)] = [("🎩", 20), ("👑", 50), ("🎀", 15), ("🧢", 15), ("🎧", 30)]

    var body: some View {
        NavigationStack {
            Form {
                Section("Персонаж") {
                    TextField("Имя", text: $s.pet.name)
                    Picker("Вид", selection: $s.pet.species) {
                        ForEach(species, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Аксессуар", selection: $s.pet.accessory) {
                        ForEach(s.pet.owned, id: \.self) { Text($0.isEmpty ? "Нет" : $0).tag($0) }
                    }
                    VStack(alignment: .leading) {
                        Text("Цвет фона").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $s.pet.hue)
                    }
                }
                Section("Магазин · 🪙 \(s.pet.coins)") {
                    ForEach(prices.filter { !s.pet.owned.contains($0.0) }, id: \.0) { item in
                        Button("\(item.0)  за \(item.1) 🪙") {
                            if s.pet.coins >= item.1 {
                                s.pet.coins -= item.1
                                s.pet.owned.append(item.0)
                                s.pet.accessory = item.0
                            }
                        }
                        .disabled(s.pet.coins < item.1)
                    }
                }
                Section {
                    SecureField("Ключ OpenAI (sk-…)", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Модель", text: $s.model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Сохранить ключ") { Keychain.save(key); key = "" }.disabled(key.isEmpty)
                    Button("Очистить чат", role: .destructive) { s.chat = [] }
                } header: { Text("ChatGPT") } footer: {
                    Text("Нужен API-ключ с platform.openai.com (подписка ChatGPT его не включает). Ключ хранится в Keychain на устройстве.")
                }
            }
            .navigationTitle("Вид")
            .onAppear { /* ключ не показываем */ }
        }
    }
}

// MARK: - Мини-игра
struct GameView: View {
    @EnvironmentObject var s: Store
    @Environment(\.dismiss) private var dismiss
    @State private var score = 0
    @State private var left = 25
    @State private var pos = CGPoint(x: 150, y: 300)
    @State private var size = CGSize(width: 300, height: 600)
    private let timer = Timer.publish(every: 0.8, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { g in
            ZStack {
                VStack {
                    Text("⭐️ \(score)   Осталось ходов: \(left)").font(.title3.bold())
                    Spacer()
                }.padding()
                if left <= 0 {
                    VStack(spacing: 12) {
                        Text("Готово! +\(score) 🪙").font(.title)
                        Button("Закрыть") { dismiss() }.buttonStyle(.borderedProminent)
                    }
                } else {
                    Text("⭐️").font(.system(size: 56)).position(pos)
                        .onTapGesture { score += 1; move(g.size) }
                }
            }
            .onAppear { size = g.size; move(g.size) }
        }
        .onReceive(timer) { _ in
            guard left > 0 else { return }
            left -= 1
            if left == 0 {
                s.pet.coins += score
                s.pet.mood = clamp(s.pet.mood + 0.1)
            } else { move(size) }
        }
    }
    func move(_ g: CGSize) {
        let x = CGFloat.random(in: 40...max(41, g.width - 40))
        let y = CGFloat.random(in: 100...max(101, g.height - 40))
        pos = CGPoint(x: x, y: y)
    }
}

// MARK: - Голосовой ввод (русский)
final class Dictation: ObservableObject {
    @Published var text = ""
    @Published var listening = false
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func toggle() { listening ? stop() : start() }

    private func start() {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else { return }
            DispatchQueue.main.async { self.begin() }
        }
    }
    private func begin() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in
            req.append(buf)
        }
        engine.prepare()
        do { try engine.start() } catch { return }
        listening = true
        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                if let r = result { self?.text = r.bestTranscription.formattedString }
                if error != nil || result?.isFinal == true { self?.stop() }
            }
        }
    }
    func stop() {
        guard listening else { return }
        listening = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
    }
}
