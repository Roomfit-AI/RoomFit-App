import Foundation
import RoomPlan
import SceneKit
import simd
import UIKit

enum ScanPhase {
    case idle
    case preparing
    case scanning
    case processing
    case completed
}

@MainActor
final class RoomScanController: NSObject, ObservableObject {
    @Published var isScanning = false
    @Published var phase: ScanPhase = .idle
    @Published var capturedRoom: CapturedRoom?
    @Published var exportedFileURL: URL?
    @Published var jsonPreviewText: String?
    @Published var statusText = "스캔할 준비가 되었습니다."
    @Published var isUploadingToBackend = false
    @Published var uploadMessage: String?
    /// A snapshot of the finished 3D room model, taken once the scan completes —
    /// used as the thumbnail for this room in the uploaded-rooms list.
    @Published var lastThumbnail: UIImage?
    /// The finished scan exported as USDZ, ready to preview inline — shown in
    /// place of a flat capture image on the completed screen.
    @Published var lastModelURL: URL?
    /// Human-readable trace of how this scan's room/wall/furniture geometry was
    /// derived — shareable so it can be sent along when something looks off,
    /// without needing Xcode's console attached.
    @Published var lastDebugInfo: String?

    private weak var captureSession: RoomCaptureSession?
    private let roomBuilder = RoomBuilder(options: [.beautifyObjects])
    private let uploadService = RoomUploadService()
    private let uploadHistory: UploadedRoomStore
    private var debugLogLines: [String] = []

    init(uploadHistory: UploadedRoomStore) {
        self.uploadHistory = uploadHistory
    }

    var canExportJSON: Bool {
        capturedRoom != nil || jsonPreviewText != nil
    }

    func attach(_ captureSession: RoomCaptureSession) {
        self.captureSession = captureSession
        captureSession.delegate = self
    }

    func startScan() {
        guard RoomCaptureSession.isSupported else {
            statusText = "이 기기에서는 RoomPlan을 지원하지 않습니다."
            return
        }

        guard let captureSession else {
            statusText = "스캐너가 아직 준비되지 않았습니다."
            return
        }

        // 이전 세션이 아직 돌고 있으면 먼저 정지
        if isScanning {
            captureSession.stop()
        }

        // 상태 초기화
        capturedRoom = nil
        exportedFileURL = nil
        jsonPreviewText = nil
        uploadMessage = nil
        lastThumbnail = nil
        if let lastModelURL {
            try? FileManager.default.removeItem(at: lastModelURL)
        }
        lastModelURL = nil
        lastDebugInfo = nil
        debugLogLines = []
        isScanning = false  // 잠깐 false로 리셋

        // 약간의 딜레이 후 새 스캔 시작 (이전 세션 정리 시간 확보)
        phase = .preparing
        statusText = "스캐너를 준비하는 중..."
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))

            var configuration = RoomCaptureSession.Configuration()
            configuration.isCoachingEnabled = true
            captureSession.run(configuration: configuration)
            isScanning = true
            phase = .scanning
            statusText = "스캔 중..."
        }
    }

    func stopScan() {
        guard isScanning else { return }

        isScanning = false  // 먼저 false로 바꿔서 UI 반응 즉시
        phase = .processing
        statusText = "스캔 결과를 처리하는 중..."
        captureSession?.stop()
    }

    func saveJSON() {
        do {
            let url = try exportJSON()
            statusText = "저장됨: \(url.lastPathComponent)"
        } catch {
            showError(error)
        }
    }

    func generateMockRoomJSON() {
        capturedRoom = nil
        exportedFileURL = nil
        jsonPreviewText = makeJSONString(
            from: RoomFitRoomJSON(
                room: RoomFitRoom(width: 3.2, depth: 4.5, height: 2.4),
                openings: [],
                furniture: []
            )
        )
        uploadMessage = nil
        phase = .completed
        statusText = "테스트용 방 데이터가 준비되었습니다."
    }

    func createManualRoomJSON(widthText: String, depthText: String, heightText: String) {
        do {
            let width = try parseMeasurement(from: widthText, fieldName: "방 너비")
            let depth = try parseMeasurement(from: depthText, fieldName: "방 깊이")
            let height = try parseMeasurement(from: heightText, fieldName: "방 높이")

            capturedRoom = nil
            exportedFileURL = nil
            jsonPreviewText = makeJSONString(
                from: RoomFitRoomJSON(
                    room: RoomFitRoom(width: width, depth: depth, height: height),
                    openings: [],
                    furniture: []
                )
            )
            uploadMessage = nil
            phase = .completed
            statusText = "입력한 방 데이터가 준비되었습니다."
        } catch {
            showError(error)
        }
    }

    func uploadJSONToBackend(name: String) {
        guard !isUploadingToBackend else { return }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? "이름 없는 방" : trimmedName
        let thumbnail = lastThumbnail
        let modelSourceURL = exportUSDZIfPossible()

        do {
            let data = try exportJSONData(name: finalName)
            isUploadingToBackend = true
            uploadMessage = nil
            statusText = "방 데이터를 업로드하는 중..."

            Task { @MainActor in
                do {
                    let response = try await uploadService.uploadRoomJSON(data)
                    isUploadingToBackend = false
                    uploadMessage = "업로드 완료. roomId: \(response.roomId)"
                    statusText = "업로드가 완료되었습니다."
                    uploadHistory.add(
                        roomId: response.roomId,
                        name: response.name ?? finalName,
                        thumbnail: thumbnail,
                        modelSourceURL: modelSourceURL,
                        jsonData: data
                    )
                } catch {
                    isUploadingToBackend = false
                    let message = "업로드 실패: \(error.localizedDescription)"
                    uploadMessage = message
                    statusText = message
                    if let modelSourceURL { try? FileManager.default.removeItem(at: modelSourceURL) }
                }
            }
        } catch {
            let message = "업로드 실패: \(error.localizedDescription)"
            uploadMessage = message
            statusText = message
            if let modelSourceURL { try? FileManager.default.removeItem(at: modelSourceURL) }
        }
    }

    /// Exports the finished RoomPlan capture as a USDZ so the uploaded-rooms
    /// list can show an interactive 3D preview later. Returns nil for
    /// mock/manual entries (no CapturedRoom) or if the export itself fails.
    private func exportUSDZIfPossible() -> URL? {
        guard let capturedRoom else { return nil }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).usdz")
        do {
            // `.mesh` uses the raw captured geometry, which carries real scan
            // noise/skew and looks visibly different from the idealized rectangle
            // the web frontend draws from this same room's width/depth — `.parametric`
            // is RoomPlan's own straightened, idealized version and matches that
            // mental model much better. (The "walls look thin" complaint this was
            // meant to fix was actually about our own synthetic gap-fill patches
            // below, which are addressed directly with real thickness now.)
            try capturedRoom.export(to: url, exportOptions: .parametric)
        } catch {
            return nil
        }

        // Best-effort only: patch in flat wall segments over any uncovered stretch
        // of the room's perimeter (a fully missing side, or just part of one — e.g.
        // an entryway deliberately left out of the scan) so the model reads as an
        // enclosed room instead of showing a hole. Any failure here just leaves the
        // untouched RoomPlan export in place.
        if let frame = makeReferenceFrame(from: capturedRoom) {
            closeWallGaps(in: url, capturedRoom: capturedRoom, frame: frame)
        }

        return url
    }

    /// Adds a synthetic wall plane over every uncovered stretch of the room's
    /// perimeter — not just sides with zero walls, but gaps *between* or *around*
    /// walls that were captured. Assumes the USDZ export shares the same world
    /// coordinate space as `capturedRoom`'s own surface transforms (true for
    /// RoomPlan's own `export(to:exportOptions:)`), since patches are positioned
    /// using that frame.
    private func closeWallGaps(in usdzURL: URL, capturedRoom: CapturedRoom, frame: RoomReferenceFrame) {
        let gapsBySide = WallSide.allCases.map { side in
            (side, coverageGaps(for: side, capturedRoom: capturedRoom, frame: frame))
        }
        guard gapsBySide.contains(where: { !$0.1.isEmpty }) else { return }

        guard let scene = try? SCNScene(url: usdzURL, options: nil) else { return }
        let wallHeight = roomHeight(from: capturedRoom)

        for (side, gaps) in gapsBySide {
            for gap in gaps {
                let (cornerA, cornerB) = cornerPoints(for: side, start: gap.start, end: gap.end, frame: frame)
                let worldA = worldPoint(fromCornerX: cornerA.x, cornerZ: cornerA.z, frame: frame)
                let worldB = worldPoint(fromCornerX: cornerB.x, cornerZ: cornerB.z, frame: frame)

                let dx = worldB.x - worldA.x
                let dz = worldB.z - worldA.z
                let length = (dx * dx + dz * dz).squareRoot()
                guard length > 0.05 else { continue }

                // A real SCNBox (not a zero-thickness SCNPlane) so the patched
                // section reads as a solid wall like its neighbors instead of a
                // paper-thin cutout.
                let wallThickness = 0.1
                let wallGeometry = SCNBox(
                    width: CGFloat(length),
                    height: CGFloat(wallHeight),
                    length: CGFloat(wallThickness),
                    chamferRadius: 0
                )
                let material = SCNMaterial()
                material.diffuse.contents = UIColor(white: 0.85, alpha: 1)
                wallGeometry.materials = Array(repeating: material, count: 6)

                let wallNode = SCNNode(geometry: wallGeometry)
                wallNode.position = SCNVector3(
                    Float((worldA.x + worldB.x) / 2),
                    Float(frame.originY + wallHeight / 2),
                    Float((worldA.z + worldB.z) / 2)
                )
                // SCNBox's local +X ("width" axis) starts aligned with world +X;
                // rotating by atan2(-dz, dx) around Y turns it to face the A→B
                // direction (SceneKit's Y-rotation matrix sends +Z toward +X for
                // positive angles).
                wallNode.eulerAngles = SCNVector3(0, Float(atan2(-dz, dx)), 0)

                scene.rootNode.addChildNode(wallNode)
            }
        }

        try? scene.write(to: usdzURL, options: nil, delegate: nil, progressHandler: nil)
    }

    /// Uncovered stretches along one side of the room's perimeter, in that side's
    /// own [0, sideLength] space — gaps under 15cm are ignored as corner/measurement
    /// noise rather than a real hole.
    private func coverageGaps(
        for side: WallSide,
        capturedRoom: CapturedRoom,
        frame: RoomReferenceFrame
    ) -> [(start: Double, end: Double)] {
        let sideLength = (side == .north || side == .south) ? frame.width : frame.depth
        let minGap = 0.15

        let intervals = capturedRoom.walls
            .filter { wallSide(of: $0, frame: frame) == side }
            .map { wallInterval($0, side: side, frame: frame) }
            .sorted { $0.start < $1.start }

        var gaps: [(start: Double, end: Double)] = []
        var cursor: Double = 0
        for interval in intervals {
            let clampedStart = max(0, interval.start)
            if clampedStart - cursor > minGap {
                gaps.append((cursor, clampedStart))
            }
            cursor = max(cursor, min(interval.end, sideLength))
        }
        if sideLength - cursor > minGap {
            gaps.append((cursor, sideLength))
        }
        return gaps
    }

    /// A wall's own span, projected onto its side's axis (x for north/south walls,
    /// z for east/west), in the room's corner-origin space — used to find gaps
    /// between/around individually-captured wall segments on the same side.
    private func wallInterval(_ wall: CapturedRoom.Surface, side: WallSide, frame: RoomReferenceFrame) -> (start: Double, end: Double) {
        let direction = normalizedXZ(wall.transform.columns.0)
        let halfLength = Double(wall.dimensions.x) / 2
        let centerX = Double(wall.transform.columns.3.x)
        let centerZ = Double(wall.transform.columns.3.z)

        let endpointA = cornerCoordinates(
            worldX: centerX + direction.x * halfLength,
            worldZ: centerZ + direction.z * halfLength,
            frame: frame
        )
        let endpointB = cornerCoordinates(
            worldX: centerX - direction.x * halfLength,
            worldZ: centerZ - direction.z * halfLength,
            frame: frame
        )

        let isNorthSouth = (side == .north || side == .south)
        let a = isNorthSouth ? endpointA.x : endpointA.z
        let b = isNorthSouth ? endpointB.x : endpointB.z
        return (min(a, b), max(a, b))
    }

    /// Two points along one side of the room's [0, width] x [0, depth] rectangle,
    /// in that corner-origin space, spanning [start, end] of that side's own axis.
    private func cornerPoints(for side: WallSide, start: Double, end: Double, frame: RoomReferenceFrame) -> (a: (x: Double, z: Double), b: (x: Double, z: Double)) {
        switch side {
        case .north: return ((start, 0), (end, 0))
        case .south: return ((start, frame.depth), (end, frame.depth))
        case .west: return ((0, start), (0, end))
        case .east: return ((frame.width, start), (frame.width, end))
        }
    }

    /// Inverse of `cornerCoordinates`/`localCoordinates`: maps a point in the room's
    /// corner-origin (0...width, 0...depth) space back to world (x, z).
    private func worldPoint(fromCornerX cornerX: Double, cornerZ: Double, frame: RoomReferenceFrame) -> (x: Double, z: Double) {
        let localX = cornerX - frame.width / 2
        let localZ = cornerZ - frame.depth / 2
        let worldX = frame.originX + localX * frame.xAxisX + localZ * frame.zAxisX
        let worldZ = frame.originZ + localX * frame.xAxisZ + localZ * frame.zAxisZ
        return (worldX, worldZ)
    }

    @discardableResult
    func exportJSON() throws -> URL {
        let data = try exportJSONData()
        let directory = try scansDirectory()
        let url = directory.appendingPathComponent(Self.fileName(), conformingTo: .json)
        try data.write(to: url, options: .atomic)

        exportedFileURL = url
        return url
    }

    @discardableResult
    func exportDebugInfo() throws -> URL {
        guard let lastDebugInfo, let data = lastDebugInfo.data(using: .utf8) else {
            throw ExportError.noRoomJSON
        }
        let directory = try scansDirectory()
        let url = directory.appendingPathComponent(Self.debugFileName(), conformingTo: .plainText)
        try data.write(to: url, options: .atomic)
        return url
    }

    func showError(_ error: Error) {
        statusText = "오류: \(error.localizedDescription)"
    }

    private func scansDirectory() throws -> URL {
        let documentsDirectory = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let scansDirectory = documentsDirectory.appendingPathComponent("RoomScans", isDirectory: true)
        try FileManager.default.createDirectory(at: scansDirectory, withIntermediateDirectories: true)
        return scansDirectory
    }

    private func exportJSONData(name: String? = nil) throws -> Data {
        guard let jsonPreviewText, let baseData = jsonPreviewText.data(using: .utf8) else {
            throw ExportError.noRoomJSON
        }

        guard let name else { return baseData }

        // The room name is only known once the user is ready to upload, well after
        // the RoomFitRoomJSON string was generated — so it's spliced in here rather
        // than threaded through every JSON-generation call site.
        guard var object = try? JSONSerialization.jsonObject(with: baseData) as? [String: Any] else {
            return baseData
        }
        object["name"] = name
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? baseData
    }

    private static func fileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "RoomScan-\(formatter.string(from: Date())).json"
    }

    private static func debugFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "RoomScan-Debug-\(formatter.string(from: Date())).txt"
    }

    private func parseMeasurement(from text: String, fieldName: String) throws -> Double {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")

        guard let value = Double(normalized), value > 0 else {
            throw ExportError.invalidMeasurement(fieldName)
        }

        return value
    }

    private func makeJSONString(from roomJSON: RoomFitRoomJSON) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(roomJSON) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private func makeRoomFitJSON(from capturedRoom: CapturedRoom) -> RoomFitRoomJSON {
        debugLogLines = []
        let frame = makeReferenceFrame(from: capturedRoom)

        let room = RoomFitRoom(
            width: roundedOffset(frame?.width ?? roomWidthFallback(from: capturedRoom)),
            depth: roundedOffset(frame?.depth ?? roomDepthFallback(from: capturedRoom)),
            height: roomHeight(from: capturedRoom)
        )
        let openings = extractOpenings(from: capturedRoom, frame: frame)
        let furniture = extractFurniture(from: capturedRoom, frame: frame)
        let walls = extractWalls(from: capturedRoom, frame: frame)

        appendRoomSummary(room: room, capturedRoom: capturedRoom, frame: frame, openings: openings, furniture: furniture)
        lastDebugInfo = debugLogLines.joined(separator: "\n")

        return RoomFitRoomJSON(room: room, walls: walls, openings: openings, furniture: furniture)
    }

    /// Appends a top-level summary (per-side wall coverage, missing sides, item
    /// counts) to `debugLogLines` after everything else has already logged its own
    /// step-by-step trace — makes the shared debug text readable top-to-bottom.
    private func appendRoomSummary(
        room: RoomFitRoom,
        capturedRoom: CapturedRoom,
        frame: RoomReferenceFrame?,
        openings: [RoomFitOpening],
        furniture: [RoomFitFurniture]
    ) {
        logDebug("---")
        logDebug("[RoomFit] room = width:\(room.width) depth:\(room.depth) height:\(room.height)")

        if let frame {
            var anyGaps = false
            for side in WallSide.allCases {
                let sideWalls = capturedRoom.walls.filter { wallSide(of: $0, frame: frame) == side }
                let totalLength = sideWalls.reduce(0) { $0 + Double($1.dimensions.x) }
                let gaps = coverageGaps(for: side, capturedRoom: capturedRoom, frame: frame)
                let gapDescription = gaps.isEmpty
                    ? "no gaps"
                    : "gap(s): " + gaps.map { "\(roundedOffset($0.start))-\(roundedOffset($0.end))" }.joined(separator: ", ")
                logDebug("[RoomFit] side \(side.rawValue): \(sideWalls.count) wall(s), total length \(roundedOffset(totalLength)), \(gapDescription)")
                anyGaps = anyGaps || !gaps.isEmpty
            }
            logDebug(anyGaps ? "[RoomFit] gaps found — patched with synthetic wall(s) in the 3D export" : "[RoomFit] wall loop looks closed")
        } else {
            logDebug("[RoomFit] no reference frame — room size used a raw wall-dimension fallback")
        }

        logDebug("[RoomFit] walls exported: \(capturedRoom.walls.count), openings: \(openings.count), furniture: \(furniture.count)")
    }

    // MARK: - Room-local coordinate frame
    //
    // RoomPlan reports every position/rotation in an arbitrary ARKit world
    // coordinate system, not aligned to the room's own axes. Without correcting
    // for the room's own origin/yaw, furniture positions and rotations can't be
    // placed consistently inside the reported width x depth rectangle. Every
    // furniture/opening coordinate below is expressed relative to this frame,
    // with the origin at the room's near-left corner (0...width, 0...depth).

    private struct RoomReferenceFrame {
        let originX: Double
        let originZ: Double
        let originY: Double // world Y of the floor, used as the sill-height reference
        let xAxisX: Double
        let xAxisZ: Double
        let zAxisX: Double
        let zAxisZ: Double
        let width: Double
        let depth: Double
    }

    private enum WallSide: String, CaseIterable {
        case north, south, east, west
    }

    private func logDebug(_ message: String) {
        print(message)
        debugLogLines.append(message)
    }

    private func makeReferenceFrame(from capturedRoom: CapturedRoom) -> RoomReferenceFrame? {
        if #available(iOS 17.0, *), let floor = capturedRoom.floors.first {
            logDebug("[RoomFit] floor.dimensions = \(floor.dimensions) (x,y,z)")
            if let frame = referenceFrame(fromFloor: floor), frame.depth > 0.3, frame.width > 0.3 {
                logDebug("[RoomFit] using floor-derived frame: width=\(frame.width) depth=\(frame.depth)")
                return frame
            }
            logDebug("[RoomFit] floor-derived frame looked degenerate, falling back to walls")
        } else {
            logDebug("[RoomFit] no floors available (pre-iOS17 or empty), using wall fallback")
        }

        let fallback = referenceFrame(fromWalls: capturedRoom.walls)
        logDebug("[RoomFit] wall count = \(capturedRoom.walls.count)")
        for (index, wall) in capturedRoom.walls.enumerated() {
            let t = wall.transform
            logDebug("[RoomFit] wall[\(index)] length(dimensions.x)=\(wall.dimensions.x) origin=(\(t.columns.3.x), \(t.columns.3.z))")
        }
        if let fallback {
            logDebug("[RoomFit] wall-derived frame: width=\(fallback.width) depth=\(fallback.depth)")
        } else {
            logDebug("[RoomFit] wall-derived frame is nil (no walls at all)")
        }
        return fallback
    }

    /// `Surface.dimensions` always puts the surface's own normal/thickness in `.z` — for a
    /// wall that's the (horizontal) thickness, for a floor it's the (near-zero) vertical
    /// slab thickness. So a floor's *second* horizontal extent lives in `.y`, not `.z`, and
    /// its local Y axis (not Z) is the one that's actually horizontal. Reading `.z`/`columns.2`
    /// here previously collapsed room depth to ~0 on real scans.
    /// If the result still looks degenerate, `makeReferenceFrame` falls back to the
    /// wall-bounding-box method below instead of trusting this blindly.
    private func referenceFrame(fromFloor floor: CapturedRoom.Surface) -> RoomReferenceFrame? {
        let transform = floor.transform
        let xAxis = normalizedXZ(transform.columns.0)
        let zAxis = normalizedXZ(transform.columns.1)

        return RoomReferenceFrame(
            originX: Double(transform.columns.3.x),
            originZ: Double(transform.columns.3.z),
            originY: Double(transform.columns.3.y),
            xAxisX: xAxis.x, xAxisZ: xAxis.z,
            zAxisX: zAxis.x, zAxisZ: zAxis.z,
            width: Double(abs(floor.dimensions.x)),
            depth: Double(abs(floor.dimensions.y))
        )
    }

    /// Pre-iOS 17 fallback: `floors`/`polygonCorners` aren't available, so the frame
    /// is derived from the wall with the room's bounding box built from each wall's endpoints.
    private func referenceFrame(fromWalls walls: [CapturedRoom.Surface]) -> RoomReferenceFrame? {
        guard let referenceWall = walls.first else { return nil }

        let refTransform = referenceWall.transform
        let xAxis = normalizedXZ(refTransform.columns.0)
        let zAxis = normalizedXZ(refTransform.columns.2)
        let originX = Double(refTransform.columns.3.x)
        let originZ = Double(refTransform.columns.3.z)

        var minX = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var minZ = Double.greatestFiniteMagnitude
        var maxZ = -Double.greatestFiniteMagnitude

        for wall in walls {
            let wallTransform = wall.transform
            let direction = normalizedXZ(wallTransform.columns.0)
            let halfLength = Double(wall.dimensions.x) / 2
            let centerX = Double(wallTransform.columns.3.x)
            let centerZ = Double(wallTransform.columns.3.z)

            for sign in [1.0, -1.0] {
                let endpointX = centerX + direction.x * halfLength * sign
                let endpointZ = centerZ + direction.z * halfLength * sign
                let dx = endpointX - originX
                let dz = endpointZ - originZ
                let localX = dx * xAxis.x + dz * xAxis.z
                let localZ = dx * zAxis.x + dz * zAxis.z
                minX = min(minX, localX); maxX = max(maxX, localX)
                minZ = min(minZ, localZ); maxZ = max(maxZ, localZ)
            }
        }

        guard minX.isFinite, maxX.isFinite, minZ.isFinite, maxZ.isFinite else { return nil }

        let centerLocalX = (minX + maxX) / 2
        let centerLocalZ = (minZ + maxZ) / 2
        let floorY = Double(refTransform.columns.3.y) - Double(referenceWall.dimensions.y) / 2

        return RoomReferenceFrame(
            originX: originX + centerLocalX * xAxis.x + centerLocalZ * zAxis.x,
            originZ: originZ + centerLocalX * xAxis.z + centerLocalZ * zAxis.z,
            originY: floorY,
            xAxisX: xAxis.x, xAxisZ: xAxis.z,
            zAxisX: zAxis.x, zAxisZ: zAxis.z,
            width: maxX - minX,
            depth: maxZ - minZ
        )
    }

    private func normalizedXZ(_ column: SIMD4<Float>) -> (x: Double, z: Double) {
        let x = Double(column.x), z = Double(column.z)
        let length = (x * x + z * z).squareRoot()
        guard length > 0 else { return (1, 0) }
        return (x / length, z / length)
    }

    /// Room-local, center-origin coordinates (range roughly -extent/2...+extent/2).
    private func localCoordinates(worldX: Double, worldZ: Double, frame: RoomReferenceFrame) -> (x: Double, z: Double) {
        let dx = worldX - frame.originX
        let dz = worldZ - frame.originZ
        let localX = dx * frame.xAxisX + dz * frame.xAxisZ
        let localZ = dx * frame.zAxisX + dz * frame.zAxisZ
        return (localX, localZ)
    }

    /// Room-local, corner-origin coordinates (range 0...width, 0...depth) — matches the backend's convention.
    private func cornerCoordinates(worldX: Double, worldZ: Double, frame: RoomReferenceFrame) -> (x: Double, z: Double) {
        let local = localCoordinates(worldX: worldX, worldZ: worldZ, frame: frame)
        return (local.x + frame.width / 2, local.z + frame.depth / 2)
    }

    private func localRotationDegrees(from transform: simd_float4x4, frame: RoomReferenceFrame) -> Double {
        let objectYaw = atan2(Double(transform.columns.0.z), Double(transform.columns.0.x))
        let frameYaw = atan2(frame.xAxisZ, frame.xAxisX)
        var degrees = (objectYaw - frameYaw) * 180.0 / .pi
        degrees = degrees.truncatingRemainder(dividingBy: 360)
        if degrees < 0 { degrees += 360 }
        // Rounding a value like 359.997 can land exactly on 360 — fold that back to 0
        // so callers never see a rotation outside [0, 360).
        var rounded = roundedOffset(degrees)
        if rounded >= 360 { rounded -= 360 }
        return rounded
    }

    private func wallSide(of wall: CapturedRoom.Surface, frame: RoomReferenceFrame) -> WallSide {
        let direction = normalizedXZ(wall.transform.columns.0)
        let alongX = abs(direction.x * frame.xAxisX + direction.z * frame.xAxisZ)
        let alongZ = abs(direction.x * frame.zAxisX + direction.z * frame.zAxisZ)

        let center = localCoordinates(
            worldX: Double(wall.transform.columns.3.x),
            worldZ: Double(wall.transform.columns.3.z),
            frame: frame
        )

        if alongX >= alongZ {
            return center.z >= 0 ? .south : .north
        } else {
            return center.x >= 0 ? .east : .west
        }
    }

    /// Finds the wall a door/window belongs to. Uses RoomPlan's own parent link on iOS 17+;
    /// falls back to nearest-wall-by-distance since `parentIdentifier` isn't available on iOS 16.
    private func resolveWall(for surface: CapturedRoom.Surface, walls: [CapturedRoom.Surface]) -> CapturedRoom.Surface? {
        if #available(iOS 17.0, *),
           let parentId = surface.parentIdentifier,
           let wall = walls.first(where: { $0.identifier == parentId }) {
            return wall
        }
        return nearestWall(to: surface, in: walls)
    }

    private func nearestWall(to surface: CapturedRoom.Surface, in walls: [CapturedRoom.Surface]) -> CapturedRoom.Surface? {
        let point = (x: Double(surface.transform.columns.3.x), z: Double(surface.transform.columns.3.z))
        return walls.min { distanceToWallLine($0, point: point) < distanceToWallLine($1, point: point) }
    }

    private func distanceToWallLine(_ wall: CapturedRoom.Surface, point: (x: Double, z: Double)) -> Double {
        let direction = normalizedXZ(wall.transform.columns.0)
        let halfLength = Double(wall.dimensions.x) / 2
        let centerX = Double(wall.transform.columns.3.x)
        let centerZ = Double(wall.transform.columns.3.z)

        let toPointX = point.x - centerX
        let toPointZ = point.z - centerZ
        let alongWall = max(-halfLength, min(halfLength, toPointX * direction.x + toPointZ * direction.z))
        let closestX = centerX + direction.x * alongWall
        let closestZ = centerZ + direction.z * alongWall

        let dx = point.x - closestX
        let dz = point.z - closestZ
        return (dx * dx + dz * dz).squareRoot()
    }

    // MARK: - Openings

    private func extractOpenings(from capturedRoom: CapturedRoom, frame: RoomReferenceFrame?) -> [RoomFitOpening] {
        guard let frame else { return [] }

        func wallSideAndOffset(for surface: CapturedRoom.Surface) -> (WallSide, Double)? {
            guard let wall = resolveWall(for: surface, walls: capturedRoom.walls) else { return nil }
            let side = wallSide(of: wall, frame: frame)
            let corner = cornerCoordinates(
                worldX: Double(surface.transform.columns.3.x),
                worldZ: Double(surface.transform.columns.3.z),
                frame: frame
            )
            let offset = (side == .north || side == .south) ? corner.x : corner.z
            return (side, roundedOffset(offset))
        }

        var openings: [RoomFitOpening] = []

        for door in capturedRoom.doors {
            guard let (side, offset) = wallSideAndOffset(for: door) else { continue }
            openings.append(RoomFitOpening(
                id: door.identifier.uuidString,
                type: "door",
                wall: side.rawValue,
                offset: offset,
                width: roundedOffset(Double(door.dimensions.x)),
                height: roundedOffset(Double(door.dimensions.y)),
                sillHeight: nil
            ))
        }

        for window in capturedRoom.windows {
            guard let (side, offset) = wallSideAndOffset(for: window) else { continue }
            let bottomY = Double(window.transform.columns.3.y) - Double(window.dimensions.y) / 2
            openings.append(RoomFitOpening(
                id: window.identifier.uuidString,
                type: "window",
                wall: side.rawValue,
                offset: offset,
                width: roundedOffset(Double(window.dimensions.x)),
                height: roundedOffset(Double(window.dimensions.y)),
                sillHeight: roundedOffset(max(0, bottomY - frame.originY))
            ))
        }

        return openings
    }

    // MARK: - Walls

    /// The real captured wall segments (start/end in the same corner-origin space
    /// as furniture/opening coordinates) — lets consumers (e.g. the web frontend)
    /// draw the room's true shape instead of only having a width x height
    /// rectangle to idealize from.
    private func extractWalls(from capturedRoom: CapturedRoom, frame: RoomReferenceFrame?) -> [RoomFitWall] {
        guard let frame else { return [] }

        return capturedRoom.walls.map { wall -> RoomFitWall in
            let direction = normalizedXZ(wall.transform.columns.0)
            let halfLength = Double(wall.dimensions.x) / 2
            let centerX = Double(wall.transform.columns.3.x)
            let centerZ = Double(wall.transform.columns.3.z)

            let startCorner = cornerCoordinates(
                worldX: centerX - direction.x * halfLength,
                worldZ: centerZ - direction.z * halfLength,
                frame: frame
            )
            let endCorner = cornerCoordinates(
                worldX: centerX + direction.x * halfLength,
                worldZ: centerZ + direction.z * halfLength,
                frame: frame
            )

            return RoomFitWall(
                id: wall.identifier.uuidString,
                start: RoomFitPosition(x: roundedOffset(startCorner.x), z: roundedOffset(startCorner.z)),
                end: RoomFitPosition(x: roundedOffset(endCorner.x), z: roundedOffset(endCorner.z)),
                height: roundedOffset(Double(wall.dimensions.y)),
                thickness: roundedOffset(Double(wall.dimensions.z))
            )
        }
    }

    // MARK: - Furniture

    private func extractFurniture(from capturedRoom: CapturedRoom, frame: RoomReferenceFrame?) -> [RoomFitFurniture] {
        guard let frame else { return [] }

        // Clamping must happen against the *rounded* numbers that actually get
        // exported (this same rounding is what `room.width`/`room.depth` use in
        // `makeRoomFitJSON`) — clamping against the raw unrounded frame left a
        // ~5mm gap where footprint/position/room size, each rounded independently
        // afterwards, could still combine to poke outside the reported room rectangle.
        let roomWidth = roundedOffset(frame.width)
        let roomDepth = roundedOffset(frame.depth)

        return capturedRoom.objects.compactMap { object -> RoomFitFurniture? in
            guard let type = mapCategory(object.category) else { return nil }

            let corner = cornerCoordinates(
                worldX: Double(object.transform.columns.3.x),
                worldZ: Double(object.transform.columns.3.z),
                frame: frame
            )
            let rotation = localRotationDegrees(from: object.transform, frame: frame)
            let footprint = worldAlignedFootprint(
                rawWidth: Double(object.dimensions.x),
                rawDepth: Double(object.dimensions.z),
                rotationDegrees: rotation
            )
            let roundedWidth = roundedOffset(footprint.width)
            let roundedDepth = roundedOffset(footprint.depth)
            let clampedPosition = clampFootprintCenter(
                x: corner.x, z: corner.z,
                footprintWidth: roundedWidth, footprintDepth: roundedDepth,
                roomWidth: roomWidth, roomDepth: roomDepth
            )
            if abs(clampedPosition.x - corner.x) > 0.001 || abs(clampedPosition.z - corner.z) > 0.001 {
                logDebug(
                    "[RoomFit] clamped \(koreanLabel(for: type)) (\(object.identifier.uuidString.prefix(8))) "
                        + "position (\(roundedOffset(corner.x)), \(roundedOffset(corner.z))) -> "
                        + "(\(roundedOffset(clampedPosition.x)), \(roundedOffset(clampedPosition.z))) "
                        + "to stay inside room bounds"
                )
            }

            return RoomFitFurniture(
                id: object.identifier.uuidString,
                type: type,
                label: koreanLabel(for: type),
                width: roundedWidth,
                depth: roundedDepth,
                height: roundedOffset(Double(object.dimensions.y)),
                position: RoomFitPosition(x: roundedOffset(clampedPosition.x), z: roundedOffset(clampedPosition.z)),
                rotation: rotation,
                status: "EXISTING"
            )
        }
    }

    /// Keeps an object's full footprint inside the room's own [0, width] x [0, depth]
    /// rectangle, with a small inward margin so it sits just inside a wall rather
    /// than exactly flush with it — flush-with-the-wall (e.g. position + half-width
    /// == room width, bit-for-bit) can still fail a backend that re-derives the
    /// same bound independently and compares with `>=` or hits float noise from the
    /// JSON round-trip.
    private func clampFootprintCenter(
        x: Double, z: Double,
        footprintWidth: Double, footprintDepth: Double,
        roomWidth: Double, roomDepth: Double
    ) -> (x: Double, z: Double) {
        let margin = 0.01
        let halfWidth = footprintWidth / 2
        let halfDepth = footprintDepth / 2

        let clampedX = footprintWidth + margin * 2 >= roomWidth
            ? roomWidth / 2
            : min(max(x, halfWidth + margin), roomWidth - halfWidth - margin)

        let clampedZ = footprintDepth + margin * 2 >= roomDepth
            ? roomDepth / 2
            : min(max(z, halfDepth + margin), roomDepth - halfDepth - margin)

        return (clampedX, clampedZ)
    }

    /// The backend's boundary/collision checks only handle 0/90/180/270 rotation and expect
    /// width/depth to already be the object's extent along the room's x/z axes — so a desk
    /// that's turned sideways must report its footprint with width and depth swapped rather
    /// than its unrotated catalog dimensions. `rotationDegrees` is the room-local rotation
    /// computed above (already corrected for the room's own yaw), snapped to the nearest
    /// quadrant here purely to decide whether a swap applies.
    private func worldAlignedFootprint(
        rawWidth: Double,
        rawDepth: Double,
        rotationDegrees: Double
    ) -> (width: Double, depth: Double) {
        let normalized = rotationDegrees.truncatingRemainder(dividingBy: 180)
        let positiveNormalized = normalized < 0 ? normalized + 180 : normalized
        let isPerpendicular = positiveNormalized > 45 && positiveNormalized < 135

        return isPerpendicular ? (rawDepth, rawWidth) : (rawWidth, rawDepth)
    }

    /// MVP backend only supports bed/desk/chair/storage/rug/lamp; RoomPlan categories
    /// with no equivalent (sofa, TV, fireplace, bathtub, toilet, sink, washer/dryer,
    /// refrigerator, oven, dishwasher, stove, stairs) are dropped from the scan result.
    private func mapCategory(_ category: CapturedRoom.Object.Category) -> String? {
        switch category {
        case .bed:     return "bed"
        case .table:   return "desk"
        case .chair:   return "chair"
        case .storage: return "storage"
        default:       return nil
        }
    }

    private func koreanLabel(for type: String) -> String {
        switch type {
        case "bed":     return "침대"
        case "desk":    return "책상"
        case "chair":   return "의자"
        case "storage": return "수납장"
        default:        return type
        }
    }

    // MARK: - Room dimensions

    private func roomWidthFallback(from capturedRoom: CapturedRoom) -> Double {
        let wallWidths = capturedRoom.walls.map { sortedDimensions(from: $0.dimensions).last ?? 0 }
        return wallWidths.max() ?? 0
    }

    private func roomDepthFallback(from capturedRoom: CapturedRoom) -> Double {
        let wallWidths = capturedRoom.walls.map { sortedDimensions(from: $0.dimensions).last ?? 0 }
        let distinctWidths = wallWidths.sorted(by: >)
        return distinctWidths.dropFirst().first ?? distinctWidths.first ?? 0
    }

    private func roomHeight(from capturedRoom: CapturedRoom) -> Double {
        let wallHeights = capturedRoom.walls.map {
            let sorted = sortedDimensions(from: $0.dimensions)
            return sorted.count >= 2 ? sorted[1] : (sorted.first ?? 0)
        }
        return roundedOffset(wallHeights.max() ?? 2.4)
    }

    private func sortedDimensions(from dimensions: simd_float3) -> [Double] {
        [Double(abs(dimensions.x)), Double(abs(dimensions.y)), Double(abs(dimensions.z))].sorted()
    }

    private func roundedOffset(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}

extension RoomScanController: RoomCaptureSessionDelegate {
    nonisolated func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            if let error {
                self.isScanning = false
                self.phase = .idle
                self.showError(error)
                return
            }

            do {
                self.capturedRoom = try await self.roomBuilder.capturedRoom(from: data)
                self.exportedFileURL = nil
                if let capturedRoom = self.capturedRoom {
                    self.jsonPreviewText = self.makeJSONString(from: self.makeRoomFitJSON(from: capturedRoom))
                } else {
                    self.jsonPreviewText = nil
                }
                self.lastModelURL = self.exportUSDZIfPossible()
                self.isScanning = false
                self.phase = .completed
                self.statusText = "스캔이 완료되었습니다. 업로드할 준비가 되었습니다."
            } catch {
                self.isScanning = false
                self.phase = .idle
                self.showError(error)
            }
        }
    }
    var needsReattach: Bool {
        captureSession == nil  // weak 참조가 해제됐으면 재연결 필요
    }
}

private enum ExportError: LocalizedError {
    case noRoomJSON
    case invalidMeasurement(String)

    var errorDescription: String? {
        switch self {
        case .noRoomJSON:
            return "사용 가능한 방 데이터가 없습니다."
        case .invalidMeasurement(let fieldName):
            return "\(fieldName)은(는) 0보다 큰 숫자여야 합니다."
        }
    }
}

private struct RoomFitRoomJSON: Codable {
    let room: RoomFitRoom
    let walls: [RoomFitWall]
    let openings: [RoomFitOpening]
    let furniture: [RoomFitFurniture]
}

private struct RoomFitWall: Codable {
    let id: String
    let start: RoomFitPosition
    let end: RoomFitPosition
    let height: Double
    let thickness: Double
}

private struct RoomFitRoom: Codable {
    let width: Double
    let depth: Double
    let height: Double
    let unit: String

    init(width: Double, depth: Double, height: Double, unit: String = "meter") {
        self.width = width
        self.depth = depth
        self.height = height
        self.unit = unit
    }
}

private struct RoomFitPosition: Codable {
    let x: Double
    let z: Double
}

private struct RoomFitOpening: Codable {
    let id: String
    let type: String
    let wall: String
    let offset: Double
    let width: Double
    let height: Double
    let sillHeight: Double?
}

private struct RoomFitFurniture: Codable {
    let id: String
    let type: String
    let label: String
    let width: Double
    let depth: Double
    let height: Double
    let position: RoomFitPosition
    let rotation: Double
    let status: String
}
