import Foundation
import AppKit
import Darwin

actor ReconnectingCamera: CameraService {
    private var failure: String? = "IXUS_ABSENT: absent"
    private var statusCount = 0
    private var commands: [String] = []
    func setFailure(_ failure: String?) { self.failure = failure }
    func attempts() -> Int { statusCount }
    func recordedCommands() -> [String] { commands }
    func shutdown() async {}
    func execute(_ action: String, value: Int?, output: URL?) async throws -> CameraReply {
        commands.append(action)
        if action == "status" { statusCount += 1 }
        if let failure = failure { throw CameraFailure(message: failure) }
        if action == "frame" {
            try (Data("P6\n2 2\n255\n".utf8) + Data(repeating: 100, count: 12)).write(to: output!)
            return CameraReply(file: output!.path)
        }
        if action == "display" { return CameraReply(keepBacklightOff: value == 0) }
        return CameraReply(state: CameraState(mode: 1, modeName: "AUTO", flash: 0, zoom: 0, focus: 1000, aflock: 0, record: true, battery: 3800), live: true, displaySupported: true)
    }
}
@main struct ReconnectRegression {
    @MainActor static func waitFor(_ condition: @escaping () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(6)
        while !(await condition()) {
            guard Date() < deadline else { throw CameraFailure(message: "Reconnect timed out") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    @MainActor static func main() async {
        let suite = "ixus-reconnect-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        do {
            let service = ReconnectingCamera()
            let model = CameraModel(service: service, preferences: preferences, reconnectInterval: 0.1)
            model.start(); model.start()
            for (message, kind) in [("IXUS_ABSENT: absent", "absent"), ("permission denied", "unavailable"), ("IXUS_BUSY: busy", "occupied")] {
                await service.setFailure(message)
                try await waitFor { model.connectionKind == kind && !model.busy }
                let previous = await service.attempts()
                try await waitFor { await service.attempts() > previous }
                guard model.error == nil else { throw CameraFailure(message: "Background retry shows an alert") }
            }
            print("PASS: absent, unavailable and busy states keep retrying silently")
            await service.setFailure(nil)
            try await waitFor { model.liveFrames > 0 && model.keepBacklightOff && !model.busy }
            let firstFrames = model.liveFrames
            await service.setFailure("USB disconnected")
            try await waitFor { model.state == nil && !model.live }
            guard model.error == nil else { throw CameraFailure(message: "Disconnect shows a modal alert") }
            await service.setFailure(nil)
            try await waitFor { model.state != nil && model.live && model.keepBacklightOff && model.liveFrames > firstFrames && !model.busy }
            print("PASS: unplug/replug restores connection, preview and backlight preference")
            model.disconnect()
            try await waitFor { model.connectionKind == "disconnected" && !model.busy }
            let pausedCommands = await service.recordedCommands()
            guard pausedCommands.last == "disconnect", model.state == nil, !model.live else {
                throw CameraFailure(message: "Manual disconnect did not release the session")
            }
            try await Task.sleep(nanoseconds: 1_200_000_000)
            let stillPaused = await service.recordedCommands()
            guard stillPaused == pausedCommands else { throw CameraFailure(message: "Manual disconnect resumed camera requests") }
            model.perform("status")
            try await waitFor { model.state != nil && model.live && !model.busy }
            print("PASS: manual disconnect stops all requests until explicit reconnect")
            await model.shutdown()
            let attempts = await service.attempts()
            try await Task.sleep(nanoseconds: 1_200_000_000)
            let afterShutdown = await service.attempts()
            let commands = await service.recordedCommands()
            guard attempts == afterShutdown, !commands.contains("reclaim"), !commands.contains("capture") else { throw CameraFailure(message: "Retry continued after shutdown or reclaimed/captured") }
            print("PASS: retries stop on shutdown and never reclaim USB or take photos")
        } catch { print("FAIL:", error.localizedDescription); exit(1) }
    }
}
