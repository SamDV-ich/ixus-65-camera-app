import Foundation
import AppKit
import Darwin

actor SimulatedCamera: CameraService {
    var state = CameraState(mode: 1, modeName: "AUTO", flash: 0, zoom: 0, focus: 1000, aflock: 0, record: true, battery: 3800)
    var failFrames = false
    var displayOn = true
    var delayPoll = false
    var delayedPollStarted = false
    func holdNextPoll() { delayPoll = true; delayedPollStarted = false }
    func hasDelayedPollStarted() -> Bool { delayedPollStarted }
    func physicalChange() {
        state = CameraState(mode: 2, modeName: "P", flash: 1, zoom: 3, focus: 2000, aflock: 1, record: true, battery: 3800)
    }
    func physicalFocus(_ value: Int) {
        state = CameraState(mode: state.mode, modeName: state.modeName, flash: state.flash, zoom: state.zoom, focus: value, aflock: state.aflock, record: true, battery: 3800)
    }
    func failNextFrame() { failFrames = true }
    func shutdown() async { displayOn = true }
    func execute(_ action: String, value: Int?, output: URL?) async throws -> CameraReply {
        if action == "poll" && delayPoll {
            delayPoll = false; delayedPollStarted = true
            let oldState = state
            try await Task.sleep(nanoseconds: 400_000_000)
            return CameraReply(state: oldState)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        if action == "display" { displayOn = value == 1; return CameraReply(keepBacklightOff: !displayOn) }
        if action == "frame" {
            if failFrames { throw CameraFailure(message: "Test USB disconnect") }
            try (Data("P6\n2 2\n255\n".utf8) + Data(repeating: 100, count: 12)).write(to: output!)
            return CameraReply(file: output?.path)
        }
        if action == "flash", let value = value {
            state = CameraState(mode: 1, modeName: "AUTO", flash: value, zoom: 0, focus: 1000, aflock: 0, record: true, battery: 3800)
        }
        return CameraReply(state: state, live: true, displaySupported: true, keepBacklightOff: !displayOn)
    }
}
@main struct Regression {
    @MainActor static func waitFor(_ label: String, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(6)
        while !condition() {
            guard Date() < deadline else { throw CameraFailure(message: "Timeout: " + label) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    @MainActor static func main() async {
        setbuf(stdout,nil)
        do {
            let service = SimulatedCamera()
            let model = CameraModel(service: service)
            model.update(CameraReply(modes: ["1": "AUTO", "2": "P", "60": "SCN_SNOW", "70": "VIDEO_STD", "invalid": "AUTO"]))
            guard model.availableModes.map({ $0.id }) == [1, 2, 60], model.availableModes.last?.title == "Снег" else { throw CameraFailure(message: "Dynamic photo mode list") }
            model.mode = 60
            guard model.selectedMode.explanation.contains("снежном") else { throw CameraFailure(message: "Selected mode description") }
            model.update(CameraReply(state: CameraState(mode: 60, modeName: "SCN_SNOW", flash: 0, zoom: 0, focus: 1000, aflock: 0, record: true, battery: 3800)))
            guard model.selectedMode.title == "Снег" else { throw CameraFailure(message: "Camera mode synchronization") }
            model.state = nil
            print("PASS: dynamic modes, Russian descriptions and camera-side mode selection")
            model.start(); model.start()
            try await waitFor("automatic connection") { model.state != nil && !model.busy }
            guard model.connectionKind == "connected" else { throw CameraFailure(message: "Connection indicator") }
            let battery = try JSONDecoder().decode(CameraState.self, from: Data(#"{"mode":1,"modeName":"AUTO","flash":0,"zoom":0,"focus":1000,"aflock":0,"record":true,"battery":3800,"batteryMin":3400,"batteryMax":4200}"#.utf8))
            guard battery.batteryPercent == 50 else { throw CameraFailure(message: "Battery estimate") }
            print("PASS: automatic connection, connection status, battery estimate")
            await service.physicalChange()
            try await waitFor("idle poll") { model.zoom == 3 && model.mode == 2 && model.flash == 1 && model.focusText == "2000" && model.state?.aflock == 1 }
            guard !model.busy else { throw CameraFailure(message: "Poll disables controls") }
            print("PASS: camera-side settings synchronize while idle")
            model.startLive(); try await waitFor("initial frames") { model.liveFrames >= 3 }
            model.focusEditing = true; model.editFocus("123")
            await service.physicalFocus(3000)
            try await waitFor("live poll") { model.state?.focus == 3000 }
            guard model.focusText == "123", model.live else { throw CameraFailure(message: "Draft overwritten or preview stopped") }
            model.focusEditing = false // draft remains protected until committed
            print("PASS: polling while live preserves focus draft and preview")
            model.perform("display",value:0)
            try await waitFor("display command") { !model.busy && model.keepBacklightOff == true && model.live }
            model.perform("display",value:1)
            try await waitFor("display on") { !model.busy && model.keepBacklightOff == false }
            print("PASS: screen commands resume preview")
            let before = model.liveFrames
            model.select("flash", value: 2)
            try await waitFor("settings resume") { !model.busy && model.live && model.liveFrames > before + 2 }
            guard model.state?.flash == 2 else { throw CameraFailure(message: "Setting lost") }
            print("PASS: settings apply while live, preview resumes automatically")
            await service.holdNextPoll()
            var waited = 0
            while !(await service.hasDelayedPollStarted()) {
                waited += 1
                guard waited < 300 else { throw CameraFailure(message: "No delayed poll") }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            model.select("flash", value: 0)
            try await waitFor("new setting") { !model.busy && model.flash == 0 }
            try await Task.sleep(nanoseconds: 500_000_000)
            guard model.flash == 0 else { throw CameraFailure(message: "Old poll overwrote new command") }
            print("PASS: delayed poll cannot overwrite a newer setting")
            model.perform("flash", value: 0); model.stopLive()
            try await waitFor("setting complete") { !model.busy }
            try await Task.sleep(nanoseconds: 300_000_000)
            guard !model.live else { throw CameraFailure(message: "Stopped preview resurrected") }
            print("PASS: explicit stop during a setting prevents automatic restart")
            model.startLive(); try await waitFor("restart") { model.liveFrames >= 2 }
            await service.failNextFrame()
            try await waitFor("error stop") { !model.live && model.error != nil }
            guard model.previewLabel.contains("Связь прервана") else { throw CameraFailure(message: "Stale image not labelled") }
            print("PASS: loss of connection stops preview and labels the stale frame")
            model.connectionFailed(CameraFailure(message: "IXUS_BUSY: busy"), quietly: true)
            guard model.connectionKind == "occupied" else { throw CameraFailure(message: "Busy status") }
            model.error = nil
            model.connectionFailed(CameraFailure(message: "IXUS_ABSENT: absent"), quietly: true)
            guard model.connectionKind == "absent", model.error == nil else { throw CameraFailure(message: "Absent status") }
            model.connectionFailed(CameraFailure(message: "unknown"), quietly: true)
            guard model.connectionKind == "unavailable" else { throw CameraFailure(message: "Unknown status") }
            print("PASS: busy, absent and unknown remain distinct; background checks are silent")
            await model.shutdown()
        } catch { print("FAIL:",error.localizedDescription); exit(1) }
    }
}
