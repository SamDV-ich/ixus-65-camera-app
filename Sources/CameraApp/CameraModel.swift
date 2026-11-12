import AppKit
import SwiftUI

@MainActor final class CameraModel: ObservableObject {
    @Published var state: CameraState?
    @Published var connection = "Поиск камеры…"
    @Published var connectionKind = "searching"
    @Published var busy = false
    @Published private(set) var liveEnabled: Bool
    @Published private(set) var backlightOffEnabled: Bool
    @Published private(set) var previewDetailed: Bool
    @Published private(set) var previewFPS: Int
    @Published private(set) var previewNativeSize: Bool
    private let preferences: UserDefaults
    @Published var live = false
    @Published var liveSupported = false
    @Published var liveFrames = 0
    @Published var lastFrameAt: Date?
    @Published var previewLabel = "Нет изображения"
    @Published var cameraMenuActive = false
    @Published private(set) var previewIsLive = false
    @Published var preview: NSImage?
    @Published var lastPhoto: URL?
    @Published var message = "Ищу камеру с CHDK по USB…"
    @Published var error: String?
    @Published var saving: SaveSettings {
        didSet { if let data = try? JSONEncoder().encode(saving) { preferences.set(data, forKey: "saveSettings") } }
    }
    @Published var folder: URL
    @Published var flash = 0
    @Published var availableModes: [CaptureMode] = []
    @Published var mode = 1
    @Published var zoom = 0
    @Published var focusProblem: String?
    @Published var focusRange: Int?
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
    private let reconnectInterval: TimeInterval
    private var nextSearchAt = Date.distantPast
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
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, !ending else { return }
                if state != nil { await pollState() }
                else if !busy && Date() >= nextSearchAt {
                    perform("status", quietly: true)
                }
            }
        }
    }
    func connectionFailed(_ error: Error, quietly: Bool = false) {
        let text = error.localizedDescription
        nextSearchAt = Date().addingTimeInterval(reconnectInterval)
        state = nil; focusProblem = nil; focusRange = nil; availableModes = []; liveSupported = false; displaySupported = false; keepBacklightOff = false
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
        if cameraMenuActive { return }
        if enabled { startLive() } else { stopLive() }
    }
    func setPreviewDetailed(_ enabled: Bool) {
        previewDetailed = enabled
        preferences.set(enabled, forKey: "previewDetailed")
    }
    func setPreviewFPS(_ value: Int) {
        guard [0, 5, 10, 15].contains(value) else { return }
        previewFPS = value
        preferences.set(value, forKey: "previewFPS")
    }
    func setPreviewNativeSize(_ enabled: Bool) {
        previewNativeSize = enabled
        preferences.set(enabled, forKey: "previewNativeSize")
    }
    static func previewWait(fps: Int, elapsed: TimeInterval) -> UInt64 {
        guard fps > 0 else { return 0 }
        return UInt64(max(0, 1 / Double(fps) - elapsed) * 1_000_000_000)
    }
    func setBacklightOffEnabled(_ enabled: Bool) {
        guard !busy, !ending else { return }
        backlightOffEnabled = enabled
        preferences.set(enabled, forKey: "backlightOffEnabled")
        if state != nil && displaySupported { perform("display", value: enabled ? 0 : 1) }
    }
    init(service: (any CameraService)? = nil, preferences: UserDefaults = .standard, reconnectInterval: TimeInterval = 3) {
        self.preferences = preferences
        self.reconnectInterval = max(0, reconnectInterval)
        liveEnabled = preferences.object(forKey: "liveEnabled") as? Bool ?? true
        backlightOffEnabled = preferences.object(forKey: "backlightOffEnabled") as? Bool ?? true
        previewDetailed = preferences.bool(forKey: "previewDetailed")
        let savedFPS = preferences.object(forKey: "previewFPS") as? Int ?? 10
        previewFPS = [0, 5, 10, 15].contains(savedFPS) ? savedFPS : 10
        previewNativeSize = preferences.bool(forKey: "previewNativeSize")
        self.service = service ?? CHDKCameraService(resources: Bundle.main.resourceURL!)
        saving = preferences.data(forKey: "saveSettings").flatMap { try? JSONDecoder().decode(SaveSettings.self, from: $0) } ?? SaveSettings()
        let saved = preferences.string(forKey: "photoFolder")
        folder = saved.map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
    }
    func note(_ text: String) {
        message = text
        events.insert(Date().formatted(date: .omitted, time: .standard) + "  " + text, at: 0)
        events = Array(events.prefix(30))
    }
    func setCameraMenu(_ visible: Bool) {
        cameraMenuActive = visible
        Task {
            while busy && !ending { try? await Task.sleep(nanoseconds: 20_000_000) }
            guard !ending, state != nil else { return }
            perform("screen", value: cameraMenuActive ? 1 : 0)
        }
    }
    func options(_ control: String) -> [Int] { state?.controls?[control] ?? [] }
    func focusNow(lock: Bool? = nil) {
        let shouldLock = (lock ?? (state?.aflock == 1)) && options("focuslock").contains(1)
        focusDraftChanged = false
        focusEditing = false
        if let state = state { focusText = String(state.focus) }
        perform("focusnow", value: shouldLock ? 1 : 0)
    }
    func setFocusLocked(_ locked: Bool) {
        if !locked { perform("autofocus") }
        else if state?.focusState == 1 { perform("focuslock", value: 1) }
        else { focusNow(lock: true) }
    }
    var selectedMode: CaptureMode {
        availableModes.first { $0.id == mode } ?? CaptureMode(id: mode, name: state?.modeName ?? "AUTO")
    }
    func update(_ reply: CameraReply) {
        if let focused = reply.focusSucceeded {
            focusProblem = focused ? nil : (reply.warning ?? "Не удалось навести резкость.")
        }
        if let modes = reply.modes {
            availableModes = modes.compactMap { key, name in
                guard let id = Int(key), id > 0 else { return nil }
                let item = CaptureMode(id: id, name: name)
                return item.isPhoto ? item : nil
            }.sorted { $0.id < $1.id }
        }
        if let s = reply.state { connectionKind = "connected"; connection = "Камера под управлением приложения"; state = s; flash = s.flash; mode = s.mode; zoom = s.zoom; focusRange = s.focusRange
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
                    error = nil
                    // Enter record mode before applying the backlight preference:
                    // Canon may wake the lamp when Live View changes modes.
                    if liveEnabled && liveSupported {
                        update(try await service.execute("live", value: nil, output: nil))
                        resumeLive = true
                    }
                    if cameraMenuActive && liveSupported {
                        update(try await service.execute("screen", value: 1, output: nil))
                        resumeLive = true
                    }
                    if backlightOffEnabled && displaySupported {
                        update(try await service.execute("display", value: 0, output: nil))
                    }
                }
                if action == "screen" { resumeLive = value == 1 || liveEnabled }
                succeeded = true
                if quietly && !wasConnected { note("Камера подключена. Готова к работе.") }
                if action == "display" {
                    note(keepBacklightOff ? "Подсветка будет оставаться выключенной; приложение повторяет команду автоматически." : "Удержание подсветки выключенной отключено; команда включения отправлена.")
                } else if action == "key" {
                    note("Команда отправлена камере.")
                } else if action == "focusnow", let problem = focusProblem {
                    note(problem)
                } else if action == "focusnow" {
                    note(state?.aflock == 1 ? "Резкость наведена и зафиксирована." : "Резкость наведена. При съёмке камера сфокусируется снова.")
                } else if action == "focuslock" || action == "focus" {
                    focusProblem = nil
                    note(state?.aflock == 1 ? "Фокус зафиксирован." : "Фиксация фокуса снята.")
                } else if !quietly { note(action == "status" ? "Камера подключена. CHDK \(reply.build?.build_number ?? "") / \(reply.build?.platsub ?? "")." : "Настройка применена; состояние прочитано с камеры.") }
            } catch { connectionFailed(error, quietly: quietly) }
        }
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Сохранять сюда"
        if panel.runModal() == .OK, let url = panel.url {
            folder = url; preferences.set(url.path, forKey: "photoFolder")
        }
    }
    func setSaveDestination(_ value: Int) {
        saving.destination = value
        if value == 1 && ["png", "tiff"].contains(saving.format) { saving.format = "jpeg" }
    }
    var saveExample: String {
        if saving.destination == 1 { return "Оригиналы остаются на карте камеры" }
        do {
            try saving.validate()
            let date = Date()
            let name = try saving.basename(original: "IMG_6202.JPG", date: date)
            let ext = saving.format == "jpeg" ? "jpg" : saving.format
            return saving.directory(folder: folder, date: date).appendingPathComponent(name + "." + ext).path
        } catch { return error.localizedDescription }
    }
    func openSaveFolder() { NSWorkspace.shared.open(folder) }
    func capture() {
        guard !ending, !busy, state != nil else { return }
        let settings = saving
        do { try settings.validate() } catch { self.error = error.localizedDescription; return }
        let selectedFolder = folder
        let date = Date()
        operationRevision += 1
        let resumeLive = live
        stopLive(); busy = true
        let resumeGeneration = generation
        Task {
            var canResume = true
            var staging: URL?
            var shotRequested = false
            defer {
                busy = false
                if canResume && resumeLive && generation == resumeGeneration { beginLive() }
            }
            do {
                if settings.destination != 1 {
                    let directory = settings.directory(folder: selectedFolder, date: date)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let path = directory.appendingPathComponent(".ixus-" + UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
                    staging = path
                }
                note("Снимаю • " + settings.destinationTitle + "…")
                shotRequested = true
                let reply: CameraReply
                do { reply = try await service.execute("take", value: settings.captureCode, output: staging) }
                catch { canResume = false; connectionFailed(error); throw error }
                update(reply)
                saving.counter += 1
                if settings.destination == 1 {
                    lastPhoto = nil
                    note("Сохранено на камере: " + (reply.cameraFiles ?? []).joined(separator: ", "))
                    return
                }
                guard let staging = staging, let files = reply.capturedFiles, !files.isEmpty else { throw CameraFailure(message: "Нет списка скачанных файлов") }
                let saved = try await Task.detached {
                    try CaptureFiles.save(staging: staging, files: files, settings: settings, folder: selectedFolder, date: date)
                }.value
                lastPhoto = saved.files.first
                if let url = saved.preview, let image = NSImage(contentsOf: url) {
                    previewIsLive = false; preview = image; previewLabel = "Последний снимок"
                }
                if settings.destination == 2 {
                    do {
                        let result = try await service.execute("finishcapture", value: nil, output: nil)
                        if result.deleted != true { self.error = result.warning ?? "Файлы на Mac сохранены, но удаление с камеры не подтверждено." }
                    } catch {
                        canResume = false; connectionFailed(error)
                        self.error = "Файлы на Mac сохранены. Удаление с камеры не подтверждено: " + error.localizedDescription
                    }
                }
                try? FileManager.default.removeItem(at: staging)
                note("Сохранено: " + saved.files.map { $0.path }.joined(separator: ", ") + (settings.destination == 0 ? ". Оригиналы оставлены на карте." : ""))
            } catch {
                let recovery = staging.map { " Загруженные файлы, если они есть: " + $0.path } ?? ""
                let warning = shotRequested ? " Снимок мог быть сделан; перед повтором проверьте карту. Оригиналы автоматически не удалялись." : " Съёмка не запускалась."
                self.error = error.localizedDescription + warning + recovery
                note(self.error!)
            }
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
            defer {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + ".rgba"))
            }
            while !Task.isCancelled && current == generation {
                do {
                    let frameStarted = ProcessInfo.processInfo.systemUptime
                    let reply = try await service.execute("frame", value: previewDetailed ? 1 : 0, output: url)
                    var image = try Self.decodePPM(Data(contentsOf: url))
                    if cameraMenuActive, let overlayPath = reply.overlay {
                        let overlay = try Self.decodeOverlay(Data(contentsOf: URL(fileURLWithPath: overlayPath)))
                        let composite = NSImage(size: image.size)
                        composite.lockFocus()
                        image.draw(in: NSRect(origin: .zero, size: image.size))
                        overlay.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .sourceOver, fraction: 1)
                        composite.unlockFocus()
                        image = composite
                    }
                    // Full decoding retains more horizontal samples with non-square pixels.
                    // Keep the camera's 4:3 display proportions in either quality mode.
                    image.size = NSSize(width: image.size.height * 4 / 3, height: image.size.height)
                    guard !Task.isCancelled, current == generation else { return }
                    previewIsLive = true; preview = image; liveFrames += 1; lastFrameAt = Date()
                    previewLabel = "Live View"
                    let delay = Self.previewWait(fps: previewFPS, elapsed: ProcessInfo.processInfo.systemUptime - frameStarted)
                    if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                    else { await Task.yield() }
                } catch is CancellationError { return }
                catch {
                    guard current == generation else { return }
                    live = false; previewLabel = "Связь прервана • последний кадр"
                    connectionFailed(error, quietly: true)
                    note("Live View остановлен. Показан последний кадр. " + error.localizedDescription)
                    return
                }
            }
        }
    }
    func shutdown() async { ending = true; operationRevision += 1; monitor?.cancel(); monitor = nil; stopLive(); await service.shutdown() }
    static func decodeOverlay(_ data: Data) throws -> NSImage {
        guard let first = data.firstIndex(of: 10), let second = data[data.index(after: first)...].firstIndex(of: 10),
              String(data: data[..<first], encoding: .ascii) == "RGBA",
              let dimensions = String(data: data[data.index(after: first)..<second], encoding: .ascii) else { throw CameraFailure(message: "Некорректный экран камеры") }
        let numbers = dimensions.split(separator: " ").compactMap { Int($0) }
        let payload = Data(data[data.index(after: second)...])
        guard numbers.count == 2, numbers[0] > 0, numbers[1] > 0, numbers[0] <= 4096, numbers[1] <= 4096,
              payload.count == numbers[0] * numbers[1] * 4,
              let provider = CGDataProvider(data: payload as CFData),
              let cg = CGImage(width: numbers[0], height: numbers[1], bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: numbers[0] * 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw CameraFailure(message: "Некорректный экран камеры") }
        return NSImage(cgImage: cg, size: NSSize(width: numbers[0], height: numbers[1]))
    }
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
