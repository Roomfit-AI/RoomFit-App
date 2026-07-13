import CoreImage
import Foundation
import UIKit

struct UploadedRoomRecord: Identifiable, Codable {
    let id: UUID
    let roomId: Int
    let name: String
    let thumbnailFileName: String?
    let modelFileName: String?
    let jsonFileName: String?
    let uploadedAt: Date
}

enum UploadedRoomStoreError: LocalizedError {
    case missingJSON

    var errorDescription: String? {
        switch self {
        case .missingJSON:
            return "저장된 JSON이 없습니다."
        }
    }
}

/// Keeps a simple on-device history of rooms this app has uploaded, so the home
/// screen has something to show without needing a "list rooms" backend endpoint.
@MainActor
final class UploadedRoomStore: ObservableObject {
    @Published private(set) var records: [UploadedRoomRecord] = []

    private let recordsFileURL: URL
    private let thumbnailsDirectory: URL
    private let modelsDirectory: URL
    private let jsonDirectory: URL
    private let ciContext = CIContext()
    private let uploadService = RoomUploadService()

    init() {
        let documentsDirectory = (try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory

        recordsFileURL = documentsDirectory.appendingPathComponent("UploadedRooms.json")
        thumbnailsDirectory = documentsDirectory.appendingPathComponent("RoomThumbnails", isDirectory: true)
        modelsDirectory = documentsDirectory.appendingPathComponent("RoomModels", isDirectory: true)
        jsonDirectory = documentsDirectory.appendingPathComponent("RoomJSON", isDirectory: true)
        try? FileManager.default.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: jsonDirectory, withIntermediateDirectories: true)
        load()
    }

    /// `modelSourceURL` is a temporary file (e.g. a freshly-exported USDZ) that
    /// gets moved into this store's own permanent location. `jsonData` is the
    /// exact payload that was uploaded, kept around so "JSON 공유" and viewing
    /// still work for a room opened later from this history list.
    func add(roomId: Int, name: String, thumbnail: UIImage?, modelSourceURL: URL?, jsonData: Data?) {
        let thumbnailFileName = saveThumbnail(thumbnail, roomId: roomId)
        let modelFileName = saveModel(modelSourceURL)
        let jsonFileName = saveJSON(jsonData)
        let record = UploadedRoomRecord(
            id: UUID(),
            roomId: roomId,
            name: name,
            thumbnailFileName: thumbnailFileName,
            modelFileName: modelFileName,
            jsonFileName: jsonFileName,
            uploadedAt: Date()
        )
        records.insert(record, at: 0)
        save()
    }

    func rename(_ record: UploadedRoomRecord, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = records.firstIndex(where: { $0.id == record.id }) else { return }

        let existing = records[index]
        records[index] = UploadedRoomRecord(
            id: existing.id,
            roomId: existing.roomId,
            name: trimmed,
            thumbnailFileName: existing.thumbnailFileName,
            modelFileName: existing.modelFileName,
            jsonFileName: existing.jsonFileName,
            uploadedAt: existing.uploadedAt
        )
        save()
    }

    /// Re-sends this record's saved JSON to the backend (with its current name
    /// spliced in, in case it was renamed locally since the original upload) and
    /// updates the local record with whatever roomId comes back. Note the backend
    /// has no "update" endpoint, so this creates a *new* room server-side rather
    /// than editing the original — acceptable for a manual retry/refresh action,
    /// but it does mean re-uploading the same room twice leaves two entries there.
    @discardableResult
    func reupload(_ record: UploadedRoomRecord) async throws -> UploadedRoomRecord {
        guard let data = renamedJSONData(for: record) else {
            throw UploadedRoomStoreError.missingJSON
        }

        let response = try await uploadService.uploadRoomJSON(data)

        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return record }
        let updated = UploadedRoomRecord(
            id: record.id,
            roomId: response.roomId,
            name: response.name ?? record.name,
            thumbnailFileName: record.thumbnailFileName,
            modelFileName: record.modelFileName,
            jsonFileName: record.jsonFileName,
            uploadedAt: Date()
        )
        records[index] = updated
        save()
        return updated
    }

    private func renamedJSONData(for record: UploadedRoomRecord) -> Data? {
        guard let url = jsonURL(for: record), let baseData = try? Data(contentsOf: url) else { return nil }
        guard var object = try? JSONSerialization.jsonObject(with: baseData) as? [String: Any] else { return baseData }
        object["name"] = record.name
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? baseData
    }

    func thumbnailImage(for record: UploadedRoomRecord) -> UIImage? {
        guard let thumbnailFileName = record.thumbnailFileName else { return nil }
        let url = thumbnailsDirectory.appendingPathComponent(thumbnailFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    func modelURL(for record: UploadedRoomRecord) -> URL? {
        guard let modelFileName = record.modelFileName else { return nil }
        let url = modelsDirectory.appendingPathComponent(modelFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func jsonURL(for record: UploadedRoomRecord) -> URL? {
        guard let jsonFileName = record.jsonFileName else { return nil }
        let url = jsonDirectory.appendingPathComponent(jsonFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func delete(_ record: UploadedRoomRecord) {
        if let thumbnailFileName = record.thumbnailFileName {
            try? FileManager.default.removeItem(at: thumbnailsDirectory.appendingPathComponent(thumbnailFileName))
        }
        if let modelFileName = record.modelFileName {
            try? FileManager.default.removeItem(at: modelsDirectory.appendingPathComponent(modelFileName))
        }
        if let jsonFileName = record.jsonFileName {
            try? FileManager.default.removeItem(at: jsonDirectory.appendingPathComponent(jsonFileName))
        }
        records.removeAll { $0.id == record.id }
        save()
    }

    private func saveModel(_ sourceURL: URL?) -> String? {
        guard let sourceURL else { return nil }

        let fileName = "\(UUID().uuidString).usdz"
        let destinationURL = modelsDirectory.appendingPathComponent(fileName)
        do {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
            return fileName
        } catch {
            return nil
        }
    }

    private func saveJSON(_ data: Data?) -> String? {
        guard let data else { return nil }

        let fileName = "\(UUID().uuidString).json"
        let url = jsonDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }

    private func saveThumbnail(_ image: UIImage?, roomId: Int) -> String? {
        guard let image else { return nil }
        let resized = resized(image, maxDimension: 240)
        let styled = tinted(resized, roomId: roomId) ?? resized
        guard let data = styled.jpegData(compressionQuality: 0.8) else { return nil }

        let fileName = "\(UUID().uuidString).jpg"
        let url = thumbnailsDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }

    /// A small rotation of the app's own accent hues (wood/sage/terracotta/slate)
    /// — same family used in the brand mockups — so the list doesn't read as one
    /// flat repeated color.
    private static let tintPalette: [CIColor] = [
        CIColor(red: 0.725, green: 0.541, blue: 0.353), // wood #B98A5A
        CIColor(red: 0.486, green: 0.522, blue: 0.404), // sage #7C8567
        CIColor(red: 0.710, green: 0.396, blue: 0.294), // terracotta #B5654B
        CIColor(red: 0.337, green: 0.439, blue: 0.541)  // slate #56708A
    ]

    /// RoomPlan's captured mesh has no color data — its raw snapshot is plain
    /// white/gray — so list thumbnails read as flat and lifeless. Tinting with a
    /// color picked deterministically from `roomId` gives each thumbnail a warm,
    /// on-brand look, with some variety from room to room instead of one repeated
    /// tone, without pretending we captured real material colors.
    private func tinted(_ image: UIImage, roomId: Int) -> UIImage? {
        guard let ciImage = CIImage(image: image),
              let filter = CIFilter(name: "CIColorMonochrome") else { return nil }

        let tintColor = Self.tintPalette[abs(roomId) % Self.tintPalette.count]
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(tintColor, forKey: kCIInputColorKey)
        filter.setValue(0.85, forKey: kCIInputIntensityKey)

        guard let output = filter.outputImage,
              let cgImage = ciContext.createCGImage(output, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }

    private func resized(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let scale = min(maxDimension / max(size.width, size.height, 1), 1)
        guard scale < 1 else { return image }

        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: recordsFileURL) else { return }
        records = (try? JSONDecoder().decode([UploadedRoomRecord].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: recordsFileURL, options: .atomic)
    }
}
