import Foundation
import ImageIO
import UniformTypeIdentifiers

struct SaveSettings: Codable, Sendable {
    var destination = 0 // 0: camera and Mac, 1: camera, 2: Mac after verified download
    var format = "jpeg"
    var keepJPEG = true
    var naming = "datetime"
    var template = "{date}_{time}_{counter}"
    var grouping = "none"
    var counter = 1
    var quality = -1
    var resolution = -1
    static let formats = ["jpeg", "png", "tiff", "raw", "dng"]
    // Optional fields migrate existing preferences without changing their outputs.
    var sensorMode: String? = nil
    var selectedMacFormats: [String]? = nil
    var cameraRetention: String? = nil
    var selectedCameraFormats: [String]? = nil
    var sensorKind: String { sensorMode ?? (["raw", "dng"].contains(format) ? format : "none") }
    var macFormats: [String] {
        if let selected = selectedMacFormats { return selected }
        if ["png", "tiff"].contains(format) { return [format] + (keepJPEG ? ["jpeg"] : []) }
        return ["raw", "dng"].contains(format) ? ["jpeg", format] : ["jpeg"]
    }
    var createdKinds: [String] { ["jpeg"] + (sensorKind == "none" ? [] : [sensorKind]) }
    var cardPolicy: String { destination == 2 ? "none" : (cameraRetention ?? "all") }
    var cardFormats: [String] {
        if cardPolicy == "none" { return [] }
        return cardPolicy == "all" ? createdKinds : (selectedCameraFormats ?? createdKinds)
    }
    var needsCameraCleanup: Bool { createdKinds.contains { !cardFormats.contains($0) } }
    var captureCode: Int {
        let raw = sensorKind == "raw" ? 1 : (sensorKind == "dng" ? 2 : 0)
        let needsJPEG = macFormats.contains { ["jpeg", "png", "tiff"].contains($0) }
        let download = destination == 1 ? 0 : ((needsJPEG ? 1 : 0) + (macFormats.contains(sensorKind) ? 2 : 0))
        let keep = (cardFormats.contains("jpeg") ? 1 : 0) + (cardFormats.contains(sensorKind) ? 2 : 0)
        return 1_000_000 + keep * 100_000 + download * 10_000 + raw + destination * 10 + (quality + 1) * 100 + (resolution + 1) * 1000
    }
    var destinationTitle: String { ["Камера и Mac", "Только камера", "Только Mac"][min(2, max(0, destination))] }
    func validate() throws {
        if destination != 1 && macFormats.isEmpty { throw CameraFailure(message: "Выберите хотя бы один файл для сохранения на Mac") }
        if destination == 1 && cardFormats.isEmpty { throw CameraFailure(message: "Выберите хотя бы один файл, который останется на камере") }
        if cardPolicy == "selected" && cardFormats.isEmpty { throw CameraFailure(message: "Выберите файлы для карты или режим «Только на Mac»") }
        guard (0...2).contains(destination), Self.formats.contains(format),
              ["datetime", "original", "custom"].contains(naming), ["none", "day", "month"].contains(grouping),
              [-1, 0, 1, 2].contains(quality), [-1, 0, 1, 2, 4, 8].contains(resolution), counter > 0, counter < 1_000_000_000,
              ["none", "raw", "dng"].contains(sensorKind), ["all", "selected", "none"].contains(cardPolicy),
              Set(macFormats).count == macFormats.count, macFormats.allSatisfy({ Self.formats.contains($0) }),
              macFormats.filter({ ["raw", "dng"].contains($0) }).allSatisfy({ $0 == sensorKind }),
              cardFormats.allSatisfy({ createdKinds.contains($0) }),
              (destination == 1 || !macFormats.isEmpty),
              (cardPolicy != "selected" || !cardFormats.isEmpty),
              (destination != 1 || !cardFormats.isEmpty) else { throw CameraFailure(message: "Некорректные настройки сохранения") }
        if naming == "custom" { _ = try basename(original: "IMG_0001.JPG", date: Date()) }
    }
    static func dateText(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = pattern
        return f.string(from: date)
    }
    func directory(folder: URL, date: Date) -> URL {
        guard grouping != "none" else { return folder }
        return folder.appendingPathComponent(Self.dateText(date, grouping == "day" ? "yyyy-MM-dd" : "yyyy-MM"), isDirectory: true)
    }
    func basename(original: String, date: Date) throws -> String {
        if naming == "original" { return URL(fileURLWithPath: original).deletingPathExtension().lastPathComponent }
        if naming == "datetime" { return Self.dateText(date, "yyyy-MM-dd_HH-mm-ss") }
        var result = template
        for (key, value) in ["date": Self.dateText(date, "yyyy-MM-dd"), "time": Self.dateText(date, "HH-mm-ss"), "counter": String(format: "%04d", counter), "original": URL(fileURLWithPath: original).deletingPathExtension().lastPathComponent] {
            result = result.replacingOccurrences(of: "{" + key + "}", with: value)
        }
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              result.utf8.count <= 180, result != ".", result != "..",
              !result.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !result.contains(where: { "/:\0\n\r{}".contains($0) }) else {
            throw CameraFailure(message: "Недопустимый шаблон имени. Используйте {date}, {time}, {counter}, {original}; без /, : и переносов строк.")
        }
        return result
    }
}
struct CapturedFile: Decodable, Sendable {
    let name: String
    let kind: String
    let size: Int
}
struct SavedCapture: Sendable { let files: [URL]; let preview: URL? }

enum CaptureFiles {
    static func validate(_ url: URL, kind: String, expectedSize: Int? = nil) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, expectedSize == nil || size == expectedSize else { throw CameraFailure(message: "Файл скачан не полностью: " + url.lastPathComponent) }
        if kind == "raw" { return }
        if kind == "dng" {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let header = try handle.read(upToCount: 4) ?? Data()
            guard size > 512, header == Data([73,73,42,0]) || header == Data([77,77,0,42]) else { throw CameraFailure(message: "Некорректный контейнер DNG") }
            return
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0, CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil,
              CGImageSourceGetType(source) as String? == (kind == "jpeg" ? UTType.jpeg.identifier : (kind == "png" ? UTType.png.identifier : UTType.tiff.identifier)) else { throw CameraFailure(message: "Не удалось проверить изображение: " + url.lastPathComponent) }
    }
    static func save(staging: URL, files: [CapturedFile], settings: SaveSettings, folder: URL, date: Date) throws -> SavedCapture {
        try settings.validate()
        guard !files.isEmpty else { throw CameraFailure(message: "Нет скачанных файлов") }
        let jpeg = files.first(where: { $0.kind == "jpeg" })
        for file in files {
            guard URL(fileURLWithPath: file.name).lastPathComponent == file.name, !file.name.contains("/"), file.size > 0 else { throw CameraFailure(message: "Некорректное имя скачанного файла") }
            // DNG is checked as a TIFF container here; RAW has no standard decoder.
            try validate(staging.appendingPathComponent(file.name), kind: file.kind, expectedSize: file.size)
        }
        let directory = settings.directory(folder: folder, date: date)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = try settings.basename(original: jpeg?.name ?? files[0].name, date: date)
        var products: [(URL, String)] = []
        for format in settings.macFormats {
            if ["png", "tiff"].contains(format) {
                guard let jpeg = jpeg else { throw CameraFailure(message: "Для преобразования нужен JPEG камеры") }
                let sourceURL = staging.appendingPathComponent(jpeg.name)
                let converted = staging.appendingPathComponent("converted." + format)
                let type = format == "png" ? UTType.png.identifier : UTType.tiff.identifier
                guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil), let writer = CGImageDestinationCreateWithURL(converted as CFURL, type as CFString, 1, nil) else { throw CameraFailure(message: "Не удалось преобразовать JPEG") }
                CGImageDestinationAddImageFromSource(writer, source, 0, nil)
                guard CGImageDestinationFinalize(writer) else { throw CameraFailure(message: "Ошибка записи преобразованного файла") }
                try validate(converted, kind: format)
                products.append((converted, format))
            } else {
                guard let file = files.first(where: { $0.kind == format }) else { throw CameraFailure(message: "Не получен выбранный файл: " + format.uppercased()) }
                products.append((staging.appendingPathComponent(file.name), format == "jpeg" ? "jpg" : format))
            }
        }
        // A single suffix keeps companions together. copyItem refuses existing files;
        // verify all products before allowing deletion of the camera originals.
        var suffix = 0
        while true {
            let stem = base + (suffix == 0 ? "" : "_\(suffix)")
            let targets = products.map { product -> URL in
                let originalBase = product.0.deletingPathExtension().lastPathComponent
                let name = settings.naming == "original" && !product.0.lastPathComponent.hasPrefix("converted.") ? originalBase + (suffix == 0 ? "" : "_\(suffix)") : stem
                return directory.appendingPathComponent(name + "." + product.1)
            }
            if targets.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) { suffix += 1; continue }
            var published: [URL] = []
            do {
                for (index, product) in products.enumerated() {
                    try FileManager.default.copyItem(at: product.0, to: targets[index]); published.append(targets[index])
                }
                for (index, target) in targets.enumerated() {
                    try validate(target, kind: products[index].1 == "jpg" ? "jpeg" : products[index].1)
                    let handle = try FileHandle(forWritingTo: target)
                    do { try handle.synchronize(); try handle.close() }
                    catch { try? handle.close(); throw error }
                }
                return SavedCapture(files: targets, preview: targets.first(where: { ["jpg", "png", "tiff"].contains($0.pathExtension) }))
            } catch {
                for path in published { try? FileManager.default.removeItem(at: path) }
                if targets.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) { suffix += 1; continue }
                throw error
            }
        }
    }
}
