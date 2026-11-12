import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Darwin

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CameraFailure(message: message) }
}
func fixture() throws -> Data {
    let bytes = Data(repeating: 110, count: 8 * 6 * 3)
    let provider = CGDataProvider(data: bytes as CFData)!
    let image = CGImage(width: 8, height: 6, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: 24, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let data = NSMutableData()
    let writer = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(writer, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
    guard CGImageDestinationFinalize(writer) else { throw CameraFailure(message: "Fixture encoding") }
    return data as Data
}
actor SavingCamera: CameraService {
    let data: Data
    var actions: [String] = []
    var badDownload = false
    var deleteFails = false
    init(_ data: Data) { self.data = data }
    func setBadDownload() { badDownload = true }
    func setDeleteFails() { deleteFails = true }
    func commands() -> [String] { actions }
    func shutdown() async {}
    func execute(_ action: String, value: Int?, output: URL?) async throws -> CameraReply {
        actions.append(action)
        if action == "take" {
            if (value ?? 0) / 10 % 10 == 1 {
                try expect(output == nil, "Camera-only created local output")
                return CameraReply(cameraFiles: ["A/DCIM/100CANON/IMG_6202.JPG"])
            }
            let payload = badDownload ? Data("broken".utf8) : data
            try payload.write(to: output!.appendingPathComponent("IMG_6202.JPG"))
            return CameraReply(capturedFiles: [CapturedFile(name: "IMG_6202.JPG", kind: "jpeg", size: payload.count)], cameraFiles: ["A/DCIM/100CANON/IMG_6202.JPG"])
        }
        if action == "finishcapture" { return CameraReply(warning: deleteFails ? "Retained on camera" : nil, deleted: !deleteFails) }
        return CameraReply()
    }
}
@main struct CaptureSavingRegression {
    @MainActor static func waitFor(_ model: CameraModel) async throws {
        let deadline = Date().addingTimeInterval(10)
        while model.busy {
            if Date() > deadline { throw CameraFailure(message: "Capture timed out") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    @MainActor static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ixus-save-test-" + UUID().uuidString)
        let suite = "ixus-save-" + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let jpeg = try fixture()
            let staging = root.appendingPathComponent("stage")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try jpeg.write(to: staging.appendingPathComponent("IMG_6202.JPG"))
            let files = [CapturedFile(name: "IMG_6202.JPG", kind: "jpeg", size: jpeg.count)]
            var settings = SaveSettings()
            settings.naming = "custom"; settings.template = "Product_{date}_{counter}"; settings.grouping = "month"
            let date = Date(timeIntervalSince1970: 1794480000)
            let first = try CaptureFiles.save(staging: staging, files: files, settings: settings, folder: root, date: date)
            let again = try CaptureFiles.save(staging: staging, files: files, settings: settings, folder: root, date: date)
            try expect(first.files != again.files, "Collision overwrote original")
            let original = try Data(contentsOf: first.files[0])
            try expect(original == jpeg, "JPEG was recompressed")
            try expect(first.files[0].deletingLastPathComponent().lastPathComponent.count == 7, "Month grouping")
            var originalSettings = SaveSettings()
            originalSettings.naming = "original"; originalSettings.grouping = "day"; originalSettings.format = "raw"
            let raw = Data(repeating: 50, count: 64)
            try raw.write(to: staging.appendingPathComponent("CRW_6202.CRW"))
            let pair = files + [CapturedFile(name: "CRW_6202.CRW", kind: "raw", size: raw.count)]
            let savedPair = try CaptureFiles.save(staging: staging, files: pair, settings: originalSettings, folder: root, date: date)
            try expect(savedPair.files.map { $0.lastPathComponent } == ["IMG_6202.jpg", "CRW_6202.raw"], "Original companion basenames")
            try expect(savedPair.files[0].deletingLastPathComponent().lastPathComponent.count == 10, "Day grouping")
            for format in ["png", "tiff"] {
                settings.format = format; settings.keepJPEG = true
                let saved = try CaptureFiles.save(staging: staging, files: files, settings: settings, folder: root, date: date)
                try expect(saved.files.count == 2 && saved.files[0].pathExtension == format, "Converted format or JPEG companion")
                let source = CGImageSourceCreateWithURL(saved.files[0] as CFURL, nil)!
                let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
                try expect(props[kCGImagePropertyPixelWidth] as? Int == 8, "Conversion changed dimensions")
                try expect(props[kCGImagePropertyOrientation] as? Int == 6, "Conversion lost orientation")
                settings.keepJPEG = false
                let without = try CaptureFiles.save(staging: staging, files: files, settings: settings, folder: root, date: date)
                try expect(without.files.count == 1, "JPEG opt-out ignored")
            }
            for template in ["../escape", "{unknown}", " ", "bad:name", "bad\nname", "bad\tname"] {
                settings.template = template
                do { try settings.validate(); throw CameraFailure(message: "Unsafe template accepted") }
                catch let e as CameraFailure { if e.message == "Unsafe template accepted" { throw e } }
            }
            settings = SaveSettings(); settings.resolution = 4; settings.quality = 2; settings.format = "dng"; settings.destination = 2
            try expect(settings.captureCode == 5322, "Capture encoding")
            print("PASS: original bytes, PNG/TIFF conversion, companions, naming, month grouping and collision protection")
            for destination in [0, 1, 2] {
                let camera = SavingCamera(jpeg)
                let model = CameraModel(service: camera, preferences: prefs)
                if destination == 0 {
                    let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
                    try expect(model.folder == pictures, "Default folder is not OS Pictures")
                }
                model.folder = root.appendingPathComponent("destination-\(destination)")
                model.saving = SaveSettings(); model.saving.destination = destination
                model.update(CameraReply(state: CameraState(mode: 1, modeName: "AUTO", flash: 0, zoom: 0, focus: 1000, aflock: 0, record: true, battery: 3800)))
                model.capture(); try await waitFor(model)
                try expect(model.error == nil, "Capture failed: " + (model.error ?? ""))
                let commands = await camera.commands()
                try expect(commands == (destination == 2 ? ["take", "finishcapture"] : ["take"]), "Wrong destination transaction")
                try expect((model.lastPhoto == nil) == (destination == 1), "Wrong local result")
                let restored = CameraModel(service: camera, preferences: prefs)
                try expect(restored.saving.destination == destination && restored.saving.counter == 2, "Saving preferences not persisted")
                await model.shutdown()
            }
            for failure in ["download", "deletion"] {
                let camera = SavingCamera(jpeg)
                if failure == "download" { await camera.setBadDownload() } else { await camera.setDeleteFails() }
                let model = CameraModel(service: camera, preferences: prefs)
                model.folder = root.appendingPathComponent(failure)
                model.saving = SaveSettings(); model.saving.destination = 2
                model.update(CameraReply(state: CameraState(mode: 1, modeName: "AUTO", flash: 0, zoom: 0, focus: 1000, aflock: 0, record: true, battery: 3800)))
                model.capture(); try await waitFor(model)
                let commands = await camera.commands()
                try expect(model.error != nil && model.state != nil, "Local saving failure disconnected camera or was hidden")
                if failure == "download" { try expect(commands == ["take"], "Deleted originals after bad download") }
                else { try expect(model.lastPhoto != nil, "Deletion error lost local result") }
                await model.shutdown()
            }
            print("PASS: destination routing, persistent settings, bad-download retention and deletion warnings without a camera")
        } catch { print("FAIL:", error.localizedDescription); exit(1) }
    }
}
