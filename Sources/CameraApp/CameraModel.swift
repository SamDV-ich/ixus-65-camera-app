import AppKit
import SwiftUI

@MainActor final class CameraModel: ObservableObject {
    @Published var state: CameraState?
    @Published var connection = "Поиск камеры…"
    @Published var connectionKind = "searching"
    @Published var busy = false
    @Published private(set) var liveEnabled: Bool
    @Published private(set) var backlightOffEnabled: Bool
    private let preferences: UserDefaults
    @Published var live = false
    @Published var liveSupported = false
    @Published var liveFrames = 0
    @Published var lastFrameAt: Date?
    @Published var previewLabel = "Нет изображения"
    @Published var preview: NSImage?
    @Published var lastPhoto: URL?
    @Published var message = "Ищу камеру с CHDK по USB…"
    @Published var error: String?
    @Published var folder: URL
    @Published var flash = 0
    @Published var availableModes: [CaptureMode] = []
    @Published var mode = 1
    @Published var zoom = 0
    @Published var focusText = "1000"
    @Published var displaySupported = false
    @Published var keepBacklightOff = false
    var focusEditing = false
    private var focusDraftChanged = false
    func editFocus(_ text: String) { focusText = text; focusDraftChanged = true }
    func finishFocusEditing() {
        focusEditing = false
        if focusDraftChanged { focusDraftChanged = false; applyFocus() }
    }
    @Published var events: [String] = []
    private let service: any CameraService
    private var liveTask: Task<Void, Never>?
    private var generation = 0
    private var monitor: Task<Void, Never>?
    private var started = false
    private var operationRevision = 0
    private var ending = false
    // Poll without toggling busy or restarting Live View. Discard responses
    // overtaken by a user operation, so old state cannot overwrite its result.
    private func pollState() async {
        guard !ending, !busy, state != nil else { return }
        let revision = operationRevision
        do {
            let reply = try await service.execute("poll", value: nil, output: nil)
            guard !ending, !busy, revision == operationRevision else { return }
            update(reply)
        } catch {
            guard !ending, !busy, revision == operationRevision else { return }
            let hadLive = live
            stopLive()
            if hadLive { previewLabel = "Связь прервана • последний кадр" }
            connectionFailed(error, quietly: true)
        }
    }
    func start() {
        guard !started else { return }; started = true
        perform("status", quietly: true)
        monitor = Task {
            var lastSearch = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, !ending else { return }
                if state != nil { await pollState() }
                else if !busy && connectionKind == "absent" && Date().timeIntervalSince(lastSearch) >= 10 {
                    lastSearch = Date(); perform("status", quietly: true)
                }
            }
        }
    }
    func connectionFailed(_ error: Error, quietly: Bool = false) {
        let text = error.localizedDescription
        state = nil; availableModes = []; liveSupported = false; displaySupported = false; keepBacklightOff = false
        connectionKind = text.contains("IXUS_BUSY:") ? "occupied" : (text.contains("IXUS_ABSENT:") ? "absent" : "unavailable")
        connection = connectionKind == "occupied" ? "Камера занята" : (connectionKind == "absent" ? "Камера не найдена" : "Камера недоступна")
        let clean = text.replacingOccurrences(of: "IXUS_BUSY: ", with: "").replacingOccurrences(of: "IXUS_ABSENT: ", with: "")
        if !quietly { self.error = clean }
        if message != clean { note(clean) }
    }
    func select(_ action: String, value: Int) { perform(action, value: value) }
    func applyFocus() {
        guard let value = Int(focusText), (100...10000).contains(value) else { error = "Введите дистанцию от 100 до 10000 мм."; return }
        perform("focus", value: value)
    }

    func setLiveEnabled(_ enabled: Bool) {
        guard !busy, !ending else { return }
        liveEnabled = enabled
        preferences.set(enabled, forKey: "liveEnabled")
        if enabled { startLive() } else { stopLive() }
    }
    func setBacklightOffEnabled(_ enabled: Bool) {
        guard !busy, !ending else { return }
        backlightOffEnabled = enabled
        preferences.set(enabled, forKey: "backlightOffEnabled")
        if state != nil && displaySupported { perform("display", value: enabled ? 0 : 1) }
    }
    init(service: (any CameraService)? = nil, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        liveEnabled = preferences.object(forKey: "liveEnabled") as? Bool ?? true
        backlightOffEnabled = preferences.object(forKey: "backlightOffEnabled") as? Bool ?? true
        self.service = service ?? CHDKCameraService(resources: Bundle.main.resourceURL!)
        let saved = UserDefaults.standard.string(forKey: "photoFolder")
        folder = saved.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/IXUS65")
    }
    func note(_ text: String) {
        message = text
        events.insert(Date().formatted(date: .omitted, time: .standard) + "  " + text, at: 0)
        events = Array(events.prefix(30))
    }
    var selectedMode: CaptureMode {
        availableModes.first { $0.id == mode } ?? CaptureMode(id: mode, name: state?.modeName ?? "AUTO")
    }
    func update(_ reply: CameraReply) {
        if let modes = reply.modes {
            availableModes = modes.compactMap { key, name in
                guard let id = Int(key), id > 0 else { return nil }
                let item = CaptureMode(id: id, name: name)
                return item.isPhoto ? item : nil
            }.sorted { $0.id < $1.id }
        }
        if let s = reply.state { connectionKind = "connected"; connection = "Камера под управлением приложения"; state = s; flash = s.flash; mode = s.mode; zoom = s.zoom
            if !focusEditing && !focusDraftChanged { focusText = String(s.focus) }
        }
        if let supported = reply.live { liveSupported = supported }
        if let supported = reply.displaySupported { displaySupported = supported }
        if let keepOff = reply.keepBacklightOff { keepBacklightOff = keepOff }
    }
    func perform(_ action: String, value: Int? = nil, quietly: Bool = false) {
        guard !ending, !busy else { return }
        operationRevision += 1
        var resumeLive = live
        let wasConnected = state != nil
        stopLive(); busy = true
        let resumeGeneration = generation
        Task {
            var succeeded = false
            defer { busy = false; if succeeded && resumeLive && generation == resumeGeneration { beginLive() } }
            do {
                let reply = try await service.execute(action, value: value, output: nil)
                update(reply)
                if !wasConnected && (action == "status" || action == "reclaim") {
                    // Enter record mode before applying the backlight preference:
                    // Canon may wake the lamp when Live View changes modes.
                    if liveEnabled && liveSupported {
                        update(try await service.execute("live", value: nil, output: nil))
                        resumeLive = true
                    }
                    if backlightOffEnabled && displaySupported {
                        update(try await service.execute("display", value: 0, output: nil))
                    }
                }
                succeeded = true
                if quietly && !wasConnected { note("Камера подключена. Готова к работе.") }
                if action == "display" {
                    note(keepBacklightOff ? "Подсветка будет оставаться выключенной; приложение повторяет команду автоматически." : "Удержание подсветки выключенной отключено; команда включения отправлена.")
                } else if !quietly { note(action == "status" ? "Камера подключена. CHDK \(reply.build?.build_number ?? "") / \(reply.build?.platsub ?? "")." : "Настройка применена; состояние прочитано с камеры.") }
            } catch { connectionFailed(error, quietly: quietly) }
        }
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Сохранять сюда"
        if panel.runModal() == .OK, let url = panel.url {
            folder = url; UserDefaults.standard.set(url.path, forKey: "photoFolder")
        }
    }
    func capture() {
        guard !ending, !busy, state != nil else { return }
        operationRevision += 1
        let resumeLive = live
        stopLive(); busy = true
        let resumeGeneration = generation
        Task {
            var succeeded = false
            defer { busy = false; if succeeded && resumeLive && generation == resumeGeneration { beginLive() } }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
                let url = folder.appendingPathComponent("IXUS65-" + formatter.string(from: Date()) + "-" + UUID().uuidString.prefix(8) + ".JPG")
                note("Снимаю и сохраняю JPEG…")
                let reply = try await service.execute("capture", value: nil, output: url)
                update(reply)
                guard let image = NSImage(contentsOf: url) else { throw CameraFailure(message: "JPEG скачан, но не удалось открыть изображение: " + url.path) }
                preview = image; lastPhoto = url; previewLabel = "Последний снимок"
                succeeded = true
                note("Сохранён " + url.lastPathComponent + ". Оригинал оставлен на SD-карте.")
            } catch { connectionFailed(error); note("Ошибка съёмки: " + error.localizedDescription + ". Перед повтором проверьте SD-карту: снимок мог быть сделан.") }
        }
    }
    func stopLive() {
        generation += 1; live = false; liveTask?.cancel(); liveTask = nil
        if lastFrameAt != nil { previewLabel = "Live View остановлен • последний кадр" }
    }
    func startLive() {
        guard !ending, !busy, state != nil, liveSupported else { return }
        operationRevision += 1
        stopLive(); busy = true
        let startGeneration = generation
        Task {
            do {
                let reply = try await service.execute("live", value: nil, output: nil)
                busy = false
                guard generation == startGeneration else { return }
                update(reply); liveFrames = 0; lastFrameAt = nil
                note("Live View включён. Настройки доступны; кадры и команды выполняются по очереди.")
                beginLive()
            } catch {
                busy = false; connectionFailed(error)
                note("Не удалось включить Live View: " + error.localizedDescription)
            }
        }
    }
    private func beginLive() {
        guard !ending, !busy, state != nil else { return }
        stopLive(); live = true; previewLabel = "Live View • ожидание кадра"
        let current = generation
        liveTask = Task {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ixus-live-" + UUID().uuidString + ".ppm")
            defer { try? FileManager.default.removeItem(at: url) }
            while !Task.isCancelled && current == generation {
                do {
                    _ = try await service.execute("frame", value: nil, output: url)
                    let image = try Self.decodePPM(Data(contentsOf: url))
                    guard !Task.isCancelled, current == generation else { return }
                    preview = image; liveFrames += 1; lastFrameAt = Date()
                    previewLabel = "Live View"
                    try await Task.sleep(nanoseconds: 150_000_000)
                } catch is CancellationError { return }
                catch {
                    guard current == generation else { return }
                    live = false; previewLabel = "Связь прервана • последний кадр"
                    connectionFailed(error)
                    note("Live View остановлен. Показан последний кадр. " + error.localizedDescription)
                    return
                }
            }
        }
    }
    func shutdown() async { ending = true; operationRevision += 1; monitor?.cancel(); monitor = nil; stopLive(); await service.shutdown() }
    // CHDKPTP produces a P6 RGB image. Display it at the camera LCD's 4:3 aspect.
    static func decodePPM(_ data: Data) throws -> NSImage {
        let bytes = [UInt8](data); var index = 0
        func token() -> String {
            while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 }
            let start = index
            while index < bytes.count && ![9,10,13,32].contains(bytes[index]) { index += 1 }
            return String(bytes: bytes[start..<index], encoding: .ascii) ?? ""
        }
        guard token() == "P6", let width = Int(token()), let height = Int(token()), token() == "255", width > 0, height > 0, width <= 4096, height <= 4096, index < bytes.count else { throw CameraFailure(message: "Некорректный кадр Live View") }
        index += 1
        guard bytes.count - index == width * height * 3,
            let provider = CGDataProvider(data: Data(bytes[index...]) as CFData),
            let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw CameraFailure(message: "Не удалось декодировать Live View") }
        return NSImage(cgImage: cg, size: NSSize(width: height * 4 / 3, height: height))
    }
}
