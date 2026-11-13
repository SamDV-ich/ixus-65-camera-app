import Foundation
import Darwin

struct CameraState: Decodable {
    let mode: Int
    let modeName: String
    let flash: Int
    let zoom: Int
    let focus: Int
    let aflock: Int
    var settings: [String: Int]? = nil
    var controls: [String: [Int]]? = nil
    var focusState: Int? = nil
    var focusRange: Int? = nil
    let record: Bool
    var batteryMin: Int? = nil
    var batteryMax: Int? = nil
    var batteryPercent: Int? {
        guard let low = batteryMin, let high = batteryMax, low > 0, high > low else { return nil }
        return min(100, max(0, (battery - low) * 100 / (high - low)))
    }
    let battery: Int
}
struct BuildInfo: Decodable { let build_number: String; let platsub: String }
struct CameraReply: Decodable {
    var state: CameraState?
    var build: BuildInfo?
    var modes: [String: String]?
    var live: Bool?
    var focusSucceeded: Bool?
    var warning: String?
    var overlay: String?
    var file: String?
    var captureFailed: Bool?
    var captureError: String?
    var shotRequested: Bool?
    var capturedFiles: [CapturedFile]?
    var cameraFiles: [String]?
    var deleted: Bool?
    var displaySupported: Bool?
    var keepBacklightOff: Bool?
}
struct Envelope: Decodable { let ok: Bool; let result: CameraReply?; let error: String?; let requestID: Int?; let connectionGeneration: Int? }
struct CameraFailure: LocalizedError { let message: String; var errorDescription: String? { message } }

// UI-independent contract; another platform can provide its own process adapter.
protocol CameraService: Sendable {
    func execute(_ action: String, value: Int?, output: URL?) async throws -> CameraReply
    func shutdown() async
}
// Owns the process and pipes so EOF closes the USB session when the service ends.
private final class CameraWorker {
    let process: Process
    let input: FileHandle
    let output: FileHandle
    var pending = Data()
    init(process: Process, input: FileHandle, output: FileHandle) {
        self.process = process; self.input = input; self.output = output
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
    }
    func close() {
        try? input.close()
        if process.isRunning { process.terminate() }
        try? output.close()
    }
    deinit { close() }
    func readLine() throws -> String? {
        while true {
            if let end = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[..<end], as: UTF8.self)
                pending.removeSubrange(...end)
                return line
            }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(output.fileDescriptor, $0.baseAddress!, $0.count) }
            if count == 0 { return nil }
            if count < 0 {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            pending.append(contentsOf: bytes.prefix(count))
            guard pending.count < 1_048_576 else { throw CameraFailure(message: "Некорректный ответ камеры") }
        }
    }
}

// A whole request is synchronous inside this actor: frame, setting and capture
// cannot interleave their USB operations, even when several tasks enqueue work.
actor CHDKCameraService: CameraService {
    private let resources: URL
    private var worker: CameraWorker?
    private var sequence = 0
    private var ending = false
    private var connectionGeneration: Int?
    private let importer: any CameraImporterControl
    private var attemptedImporterRecovery = false
    init(resources: URL, importer: any CameraImporterControl = SystemCameraImporter()) {
        self.resources = resources; self.importer = importer
    }

    private func startWorker() throws -> CameraWorker {
        if let worker = worker, worker.process.isRunning { return worker }
        worker?.close(); worker = nil
        let process = Process()
        process.executableURL = resources.appendingPathComponent("chdkptp/chdkptp")
        process.currentDirectoryURL = resources
        process.arguments = ["-r", "-e!require('ixus_bridge').worker()"]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "LUA_PATH": resources.appendingPathComponent("?.lua").path + ";" + resources.appendingPathComponent("chdkptp/lua/?.lua").path]
        let input = Pipe(); let output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = output
        try process.run()
        let created = CameraWorker(process: process, input: input.fileHandleForWriting, output: output.fileHandleForReading)
        worker = created
        return created
    }

    func execute(_ action: String, value: Int? = nil, output: URL? = nil) async throws -> CameraReply {
        guard !ending else { throw CameraFailure(message: "Приложение завершает работу") }
        do {
            let reply = try executeOnce(action, value: value, output: output)
            if action == "status" { attemptedImporterRecovery = false }
            return reply
        } catch {
            guard action == "status" else { throw error }
            let text = error.localizedDescription
            if text.contains("IXUS_ABSENT:") { attemptedImporterRecovery = false }
            let claimBlocked = text.contains("IXUS_BUSY:") || text.contains("IXUS_CLAIM_DENIED:")
            guard claimBlocked, !attemptedImporterRecovery else { throw error }
            let identifiers = importer.runningPIDs()
            guard !identifiers.isEmpty else { throw error }
            attemptedImporterRecovery = true
            closeWorker()
            try importer.stop(identifiers)
            try await Task.sleep(nanoseconds: 300_000_000)
            guard !ending else { throw CameraFailure(message: "Приложение завершает работу") }
            let reply = try executeOnce(action, value: value, output: output)
            attemptedImporterRecovery = false
            return reply
        }
    }

    private func executeOnce(_ action: String, value: Int?, output: URL?) throws -> CameraReply {
        guard ["take", "finishcapture", "status", "poll", "display", "live", "frame", "record", "play", "capture", "mode", "flash", "zoom", "focus", "focusrange", "focusnow", "focuslock", "autofocus", "iso", "wb", "ev", "metering", "screen", "key"].contains(action) else {
            throw CameraFailure(message: "Неизвестная команда камеры")
        }
        let session = try startWorker()
        sequence += 1
        let requestID = sequence
        let path = (output?.path ?? "").utf8.map { String(format: "%02x", $0) }.joined()
        let request = "\(action)\t\(value.map(String.init) ?? "")\t\(path)\t\(requestID)\n"
        let process = session.process
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        let forceStop = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        let limit: Double = (action == "capture" || action == "take") ? 90 : 25
        DispatchQueue.global().asyncAfter(deadline: .now() + limit, execute: timeout)
        DispatchQueue.global().asyncAfter(deadline: .now() + limit + 3, execute: forceStop)
        defer { timeout.cancel(); forceStop.cancel() }
        let envelope: Envelope
        do {
            try session.input.write(contentsOf: Data(request.utf8))
            var response: Envelope?
            var usbBusy = false
            var usbClaimDenied = false
            while let line = try session.readLine() {
                if line.contains("IXUS_USB_BUSY") { usbBusy = true }
                if line.contains("IXUS_USB_UNAVAILABLE") { usbClaimDenied = true }
                guard line.hasPrefix("IXUS_RESULT:") else { continue }
                let decoded = try JSONDecoder().decode(Envelope.self, from: Data(line.dropFirst(12).utf8))
                guard decoded.requestID == requestID else { throw CameraFailure(message: "Нарушена последовательность ответов камеры") }
                if usbBusy && !decoded.ok { throw CameraFailure(message: "IXUS_BUSY: USB-интерфейс камеры занят другой программой или системной службой.") }
                if usbClaimDenied && !decoded.ok { throw CameraFailure(message: "IXUS_CLAIM_DENIED: Камера видна, но доступ к её USB-интерфейсу отклонён.") }
                connectionGeneration = decoded.connectionGeneration
                response = decoded
                break
            }
            guard let received = response else { throw CameraFailure(message: "Соединение с камерой прервано. Закройте другие программы работы с камерой и нажмите «Подключить».") }
            envelope = received
        } catch {
            session.close(); worker = nil
            throw error
        }
        // A rejected camera command is never repeated. The worker stays available
        // for an explicit subsequent request; Lua resets its USB session on errors.
        guard envelope.ok, let result = envelope.result else { throw CameraFailure(message: envelope.error ?? "Ошибка камеры") }
        return result
    }

    func shutdown() async { ending = true; closeWorker() }
    private func closeWorker() {
        guard let session = worker else { return }
        try? session.input.write(contentsOf: Data("QUIT\n".utf8))
        try? session.input.close()
        let process = session.process
        let deadline = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: deadline)
        process.waitUntilExit(); deadline.cancel()
        session.close(); worker = nil
    }

    // Diagnostic for the integration check: frames and settings must use one helper.
    func workerProcessIdentifier() -> Int32? { worker?.process.processIdentifier }
    func usbConnectionGeneration() -> Int? { connectionGeneration }
}
