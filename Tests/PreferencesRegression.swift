import Foundation
import AppKit
import Darwin

actor PreferencesCamera: CameraService {
    var actions: [String] = []
    let supported: Bool
    init(supported: Bool = true) { self.supported = supported }
    func recordedActions() -> [String] { actions }
    func shutdown() async {}
    func execute(_ action: String, value: Int?, output: URL?) async throws -> CameraReply {
        actions.append(action + (value.map { ":\($0)" } ?? ""))
        if action == "frame" {
            try (Data("P6\n2 2\n255\n".utf8) + Data(repeating: 100, count: 12)).write(to: output!)
            return CameraReply(file: output!.path)
        }
        if action == "display" { return CameraReply(keepBacklightOff: value == 0) }
        return CameraReply(state: CameraState(mode: 1, modeName: "AUTO", flash: 0, zoom: 0, focus: 1000, aflock: 0, record: true, battery: 3800), live: supported, displaySupported: supported)
    }
}
@main struct PreferencesRegression {
    @MainActor static func waitFor(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { throw CameraFailure(message: "Preferences test timed out") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    @MainActor static func main() async {
        let suite = "ixus-preferences-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        do {
            let camera = PreferencesCamera()
            let model = CameraModel(service: camera, preferences: preferences)
            guard model.liveEnabled && model.backlightOffEnabled else { throw CameraFailure(message: "First-run defaults") }
            model.start()
            try await waitFor { !model.busy && model.liveFrames > 0 && model.keepBacklightOff }
            let actions = await camera.recordedActions()
            guard Array(actions.prefix(3)) == ["status", "live", "display:0"] else { throw CameraFailure(message: "Connection defaults order: \(actions)") }
            print("PASS: first connection starts preview, then disables backlight, on one service")
            model.setBacklightOffEnabled(false)
            try await waitFor { !model.busy && !model.keepBacklightOff && model.live }
            model.setLiveEnabled(false)
            guard !model.live else { throw CameraFailure(message: "Live setting did not stop preview") }
            await model.shutdown()
            let secondCamera = PreferencesCamera()
            let second = CameraModel(service: secondCamera, preferences: preferences)
            guard !second.liveEnabled && !second.backlightOffEnabled else { throw CameraFailure(message: "Preferences not persisted") }
            second.start()
            try await waitFor { !second.busy && second.state != nil }
            let secondActions = await secondCamera.recordedActions()
            guard secondActions == ["status"] else { throw CameraFailure(message: "Disabled defaults still sent commands") }
            second.setLiveEnabled(true)
            try await waitFor { !second.busy && second.liveFrames > 0 }
            second.setBacklightOffEnabled(true)
            try await waitFor { !second.busy && second.live && second.keepBacklightOff }
            await second.shutdown()
            print("PASS: changes apply immediately, survive restart and preserve preview")
            let focusCamera = PreferencesCamera(supported: false)
            let focusModel = CameraModel(service: focusCamera, preferences: preferences)
            focusModel.update(CameraReply(state: CameraState(mode: 36, modeName: "PORTRAIT", flash: 0, zoom: 0, focus: 1000, aflock: 1, controls: ["focusrange": [0,1,3]], record: true, battery: 3800)))
            focusModel.editFocus("2500")
            focusModel.focusNow()
            try await waitFor { !focusModel.busy }
            focusModel.finishFocusEditing()
            let focusActions = await focusCamera.recordedActions()
            guard focusActions == ["focusnow:0"] else { throw CameraFailure(message: "Focus button applied an old manual draft or unsupported lock") }
            await focusModel.shutdown()
            print("PASS: autofocus discards an unapplied distance and avoids locking in unsupported modes")
            let unsupportedCamera = PreferencesCamera(supported: false)
            let unsupported = CameraModel(service: unsupportedCamera, preferences: preferences)
            unsupported.start()
            try await waitFor { !unsupported.busy && unsupported.state != nil }
            let unsupportedActions = await unsupportedCamera.recordedActions()
            guard unsupportedActions == ["status"], !unsupported.live, !unsupported.keepBacklightOff else { throw CameraFailure(message: "Unsupported features were invoked") }
            await unsupported.shutdown()
            print("PASS: unsupported capabilities do not receive automatic commands")
        } catch { print("FAIL:", error.localizedDescription); exit(1) }
    }
}
