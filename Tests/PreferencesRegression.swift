import Foundation
import AppKit
import Darwin

actor PreferencesCamera: CameraService {
    var actions: [String] = []
    var rejectFocus = false
    func setRejectFocus(_ reject: Bool) { rejectFocus = reject }
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
        let current = CameraState(mode: 1, modeName: "AUTO", flash: 0, zoom: 0, focus: 1000, aflock: action == "focuslock" ? (value ?? 0) : 0, focusState: action == "focusnow" && rejectFocus ? 0 : 1, record: true, battery: 3800)
        if action == "focusnow" { return CameraReply(state: current, focusSucceeded: !rejectFocus, warning: rejectFocus ? "Cannot focus" : nil) }
        return CameraReply(state: current, live: supported, displaySupported: supported)
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
            guard !model.previewDetailed && model.previewFPS == 10 && !model.previewNativeSize else { throw CameraFailure(message: "Preview defaults") }
            guard CameraModel.previewWait(fps: 10, elapsed: 0.04) == 60_000_000,
                  CameraModel.previewWait(fps: 10, elapsed: 0.2) == 0,
                  CameraModel.previewWait(fps: 0, elapsed: 0) == 0 else { throw CameraFailure(message: "Frame budget adds delay to slow frames") }
            model.start()
            try await waitFor { !model.busy && model.liveFrames > 0 && model.keepBacklightOff }
            let actions = await camera.recordedActions()
            guard Array(actions.prefix(3)) == ["status", "live", "display:0"] else { throw CameraFailure(message: "Connection defaults order: \(actions)") }
            print("PASS: first connection starts preview, then disables backlight, on one service")
            model.setPreviewDetailed(true)
            model.setPreviewFPS(15)
            model.setPreviewNativeSize(true)
            try await waitFor { model.liveFrames >= 3 }
            let previewActions = await camera.recordedActions()
            let previewSize = model.preview?.size ?? .zero
            let previewAspect = Double(previewSize.width) / max(1, Double(previewSize.height))
            guard previewActions.contains("frame:1"), model.previewIsLive,
                  abs(previewAspect - 4.0 / 3.0) < 0.001 else { throw CameraFailure(message: "Detailed preview request or aspect ratio") }
            model.setPreviewFPS(7)
            guard model.previewFPS == 15 else { throw CameraFailure(message: "Invalid frame rate accepted") }
            print("PASS: preview quality applies during streaming; pacing accounts for processing and preserves aspect ratio")
            await camera.setRejectFocus(true)
            model.focusNow()
            try await waitFor { !model.busy && model.live && model.focusProblem != nil }
            guard model.state != nil && model.error == nil else { throw CameraFailure(message: "Normal focus refusal disconnected the camera") }
            await camera.setRejectFocus(false)
            model.focusNow()
            try await waitFor { !model.busy && model.live && model.focusProblem == nil }
            print("PASS: autofocus refusal preserves preview and connection; a successful retry clears the warning")
            model.setBacklightOffEnabled(false)
            try await waitFor { !model.busy && !model.keepBacklightOff && model.live }
            model.setLiveEnabled(false)
            guard !model.live else { throw CameraFailure(message: "Live setting did not stop preview") }
            await model.shutdown()
            let secondCamera = PreferencesCamera()
            let second = CameraModel(service: secondCamera, preferences: preferences)
            guard !second.liveEnabled && !second.backlightOffEnabled else { throw CameraFailure(message: "Preferences not persisted") }
            guard second.previewDetailed && second.previewFPS == 15 && second.previewNativeSize else { throw CameraFailure(message: "Preview preferences not persisted") }
            second.start()
            try await waitFor { !second.busy && second.state != nil }
            let secondActions = await secondCamera.recordedActions()
            guard secondActions == ["status"] else { throw CameraFailure(message: "Disabled defaults still sent commands") }
            second.setLiveEnabled(true)
            try await waitFor { !second.busy && second.liveFrames > 0 }
            second.setBacklightOffEnabled(true)
            try await waitFor { !second.busy && second.live && second.keepBacklightOff }
            second.cameraMenuActive = true
            second.setLiveEnabled(false)
            guard second.live else { throw CameraFailure(message: "Disabling main preview stopped native menu updates") }
            second.cameraMenuActive = false
            second.setLiveEnabled(false)
            guard !second.live else { throw CameraFailure(message: "Preview remained active outside native menu") }
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
            let lockCamera = PreferencesCamera(supported: false)
            let lockModel = CameraModel(service: lockCamera, preferences: preferences)
            lockModel.update(CameraReply(state: CameraState(mode: 2, modeName: "P", flash: 0, zoom: 0, focus: 1000, aflock: 0, controls: ["focuslock": [0,1]], focusState: 1, record: true, battery: 3800)))
            lockModel.setFocusLocked(true)
            try await waitFor { !lockModel.busy }
            let lockActions = await lockCamera.recordedActions()
            guard lockActions == ["focuslock:1"] && lockModel.state?.aflock == 1 else { throw CameraFailure(message: "Locking repeated autofocus instead of retaining the found distance") }
            await lockModel.shutdown()
            print("PASS: locking a confirmed focus does not run autofocus again")
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
