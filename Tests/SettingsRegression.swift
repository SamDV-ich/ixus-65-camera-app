import Foundation
import AppKit
import Darwin
@main struct SettingsRegression {
    @MainActor static func main() throws {
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        guard envelope.ok, let state = envelope.result?.state, state.controls?["focusrange"] == [0,1,3], state.controls?["iso"]?.contains(80) == true, state.settings?["wb"] == 0 else {
            fatalError("Real Lua response did not decode with numeric capability arrays")
        }
        let data = Data("RGBA\n2 2\n".utf8) + Data(repeating: 255, count: 16)
        _ = try CameraModel.decodeOverlay(data)
        do {
            _ = try CameraModel.decodeOverlay(data.dropLast())
            fatalError("Truncated overlay accepted")
        } catch is CameraFailure {}
        print("PASS: actual Lua capabilities decode in Swift; screen overlay validates dimensions and payload")
    }
}
