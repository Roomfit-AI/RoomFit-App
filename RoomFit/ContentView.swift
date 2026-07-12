import RoomPlan
import SwiftUI
import UIKit

private enum AppScreen {
    case home
    case scanning
}

struct ContentView: View {
    @StateObject private var uploadHistory: UploadedRoomStore
    @StateObject private var scanner: RoomScanController
    @State private var screen: AppScreen = .home
    @State private var shareURL: URL?
    @State private var isShowingShareSheet = false
    @State private var isShowingUnsavedRescanAlert = false
    @State private var isShowingUnsavedHomeAlert = false
    @State private var roomName = ""
    @State private var manualWidth = "3.2"
    @State private var manualDepth = "4.5"
    @State private var manualHeight = "2.4"

    init() {
        let uploadHistory = UploadedRoomStore()
        _uploadHistory = StateObject(wrappedValue: uploadHistory)
        _scanner = StateObject(wrappedValue: RoomScanController(uploadHistory: uploadHistory))
    }

    private var isRoomPlanSupported: Bool { RoomCaptureSession.isSupported }

    /// A completed scan that hasn't been confirmed-uploaded yet is about to be
    /// thrown away by rescanning or leaving — that's the moment to ask first.
    private var hasUnuploadedCompletedScan: Bool {
        scanner.phase == .completed && scanner.uploadMessage?.hasPrefix("업로드 완료") != true
    }

    var body: some View {
        Group {
            switch screen {
            case .home:
                HomeView(
                    isRoomPlanSupported: isRoomPlanSupported,
                    uploadHistory: uploadHistory,
                    onStart: startFromHome
                )
            case .scanning:
                if isRoomPlanSupported {
                    scannerView
                } else {
                    unsupportedView
                }
            }
        }
        .sheet(isPresented: $isShowingShareSheet) {
            if let shareURL {
                ShareSheet(activityItems: [shareURL])
            }
        }
        .alert("업로드되지 않은 스캔", isPresented: $isShowingUnsavedRescanAlert) {
            Button("취소", role: .cancel) {}
            Button("다시 스캔", role: .destructive) {
                roomName = ""
                scanner.startScan()
            }
        } message: {
            Text("스캔본이 업로드되지 않았습니다. 다시 스캔하시겠습니까?")
        }
        .alert("업로드되지 않은 스캔", isPresented: $isShowingUnsavedHomeAlert) {
            Button("취소", role: .cancel) {}
            Button("홈으로 나가기", role: .destructive) { screen = .home }
        } message: {
            Text("스캔본이 업로드되지 않았습니다. 홈으로 나가시겠습니까?")
        }
    }

    private func startFromHome() {
        roomName = ""
        screen = .scanning
        // Don't call scanner.startScan() here — RoomCaptureViewContainer hasn't
        // been mounted yet at this point, so captureSession is still nil and
        // startScan() would bail out with "스캐너가 아직 준비되지 않았습니다."
        // scannerView's onAppear triggers the actual start once it's attached.
    }

    private func requestRescan() {
        if hasUnuploadedCompletedScan {
            isShowingUnsavedRescanAlert = true
        } else {
            roomName = ""
            scanner.startScan()
        }
    }

    private func requestGoHome() {
        if hasUnuploadedCompletedScan {
            isShowingUnsavedHomeAlert = true
        } else {
            screen = .home
        }
    }

    // MARK: - Scanner flow

    private var scannerView: some View {
        ZStack {
            RoomCaptureViewContainer(scanner: scanner)
                // Only ignore the top edge (status bar/notch) — the bottom stays
                // inset so the bottom bar's safeAreaInset actually reserves space
                // instead of floating over the 3D scan preview.
                .ignoresSafeArea(edges: .top)

            switch scanner.phase {
            case .idle:
                retryOverlay
            case .preparing, .processing:
                loadingOverlay(text: scanner.statusText)
            case .scanning:
                VStack {
                    scanningStatusPill
                    Spacer()
                }
                .padding()
            case .completed:
                EmptyView()
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomBar
        }
        .onAppear {
            // Always kick off a fresh scan on entry — gating this on
            // `phase == .idle` meant returning here after a previous
            // *completed* scan (e.g. tapped Home without rescanning) left
            // that old completed sheet showing instead of starting over.
            scanner.startScan()
        }
    }

    /// Error-recovery state: only reachable if starting/running the capture
    /// session itself fails and phase falls back to `.idle` mid-flow.
    private var retryOverlay: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.white)

                    Text(scanner.statusText)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        scanner.startScan()
                    } label: {
                        Label("다시 시도하기", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(PillButtonStyle(kind: .ghost))

                    Button("홈으로") { screen = .home }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
            }
        }
    }

    /// Shared "loading" look for both the pre-scan setup delay and the post-scan
    /// processing delay, so neither shows a dead black screen.
    private func loadingOverlay(text: String) -> some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.4)

                Text(text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
    }

    /// Small, unobtrusive status indicator during an active scan — kept at the
    /// top so it never competes with the 3D room preview for space.
    private var scanningStatusPill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color(hex: 0xD65B3F))
                .frame(width: 7, height: 7)
            Text(scanner.statusText)
        }
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(Color(hex: 0xF4F1E9))
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.55), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
    }

    @ViewBuilder
    private var bottomBar: some View {
        switch scanner.phase {
        case .idle, .preparing, .processing:
            EmptyView()
        case .scanning:
            scanningBar
        case .completed:
            completedBar
        }
    }

    /// While actively scanning, the only thing worth doing is stopping — extra
    /// buttons and the JSON preview previously stayed on screen here and covered
    /// the 3D room preview. Kept on a dark scrim (not the cream sheet) since it
    /// sits directly over the live camera/3D capture.
    private var scanningBar: some View {
        Button {
            scanner.stopScan()
        } label: {
            Label("스캔 멈추기", systemImage: "stop.fill")
        }
        .buttonStyle(PillButtonStyle(kind: .solid))
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 30)
        .background(
            LinearGradient(colors: [.clear, Color.black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
        )
    }

    private var completedBar: some View {
        VStack(spacing: 14) {
            if let uploadMessage = scanner.uploadMessage {
                Text(uploadMessage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(uploadMessage.hasPrefix("업로드 완료") ? Color.appSage : .red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            heroThumbnail

            roomNameField

            primaryActions

            Button {
                shareJSON()
            } label: {
                Text("JSON 공유")
            }
            .buttonStyle(LinkButtonStyle())
            .disabled(!scanner.canExportJSON)
            .frame(maxWidth: .infinity)
        }
        .padding(20)
        .background(Color.appCream)
        .clipShape(RoundedCorner(radius: 28, corners: [.topLeft, .topRight]))
    }

    /// The finished scan's actual 3D model (rotate/zoom-able), or a placeholder
    /// glyph if the export hasn't landed yet — a flat capture photo here would
    /// just duplicate the live 3D view already visible behind this sheet.
    private var heroThumbnail: some View {
        Group {
            if let modelURL = scanner.lastModelURL {
                RoomModelPreview(url: modelURL)
            } else {
                IsometricRoomGlyph()
            }
        }
        .frame(height: 220)
        .frame(maxWidth: .infinity)
        .background(Color.appFloor)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.appBorder, lineWidth: 1))
    }

    private var roomNameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("방 이름")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.appInkSoft)
                .textCase(.uppercase)
                .tracking(0.4)

            TextField("우리집 거실", text: $roomName)
                .textFieldStyle(.plain)
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(Color.appCard, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.appBorder, lineWidth: 1))
        }
    }

    /// Upload + Rescan are the two actions users need after a scan.
    private var primaryActions: some View {
        VStack(spacing: 10) {
            Button {
                scanner.uploadJSONToBackend(name: roomName)
            } label: {
                HStack {
                    if scanner.isUploadingToBackend {
                        ProgressView().tint(Color.appCream)
                    } else {
                        Image(systemName: "icloud.and.arrow.up")
                    }
                    Text(scanner.isUploadingToBackend ? "업로드 중..." : "업로드하기")
                }
            }
            .buttonStyle(PillButtonStyle(kind: .solid))
            .disabled(!scanner.canExportJSON || scanner.isUploadingToBackend)

            Button {
                requestRescan()
            } label: {
                Label("다시 스캔하기", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(PillButtonStyle(kind: .ghost))

            Button {
                requestGoHome()
            } label: {
                Label("홈으로", systemImage: "house.fill")
            }
            .buttonStyle(PillButtonStyle(kind: .ghost))
        }
    }

    // MARK: - Unsupported-device flow (manual entry)

    private var unsupportedView: some View {
        ZStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 16) {
                        Image(systemName: "iphone.slash")
                            .font(.system(size: 42, weight: .semibold))
                            .foregroundStyle(Color.appInkSoft)

                        Text("이 기기에서는 RoomPlan을 지원하지 않습니다.")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Color.appInk)

                        Text("테스트용 방 데이터를 만들거나, 방 크기를 직접 입력해 JSON을 생성할 수 있습니다.")
                            .font(.subheadline)
                            .foregroundStyle(Color.appInkSoft)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        Button {
                            scanner.generateMockRoomJSON()
                        } label: {
                            Label("테스트용 방 데이터 생성", systemImage: "curlybraces")
                        }
                        .buttonStyle(PillButtonStyle(kind: .solid))

                        manualInputCard

                        if let jsonPreviewText = scanner.jsonPreviewText {
                            jsonPreview(jsonPreviewText)
                        }
                    }
                    .padding()
                    .padding(.top, 32)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                }

                unsupportedExportBar
            }

            VStack {
                HStack {
                    Button {
                        requestGoHome()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.appInkSoft)
                            .padding(10)
                            .background(Color.appCard, in: Circle())
                            .overlay(Circle().stroke(Color.appBorder, lineWidth: 1))
                    }
                    Spacer()
                }
                Spacer()
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appCream.ignoresSafeArea())
    }

    private var unsupportedExportBar: some View {
        VStack(spacing: 12) {
            if let uploadMessage = scanner.uploadMessage {
                Text(uploadMessage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(uploadMessage.hasPrefix("업로드 완료") ? Color.appSage : .red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            roomNameField

            Button {
                scanner.uploadJSONToBackend(name: roomName)
            } label: {
                HStack {
                    if scanner.isUploadingToBackend {
                        ProgressView().tint(Color.appCream)
                    } else {
                        Image(systemName: "icloud.and.arrow.up")
                    }
                    Text(scanner.isUploadingToBackend ? "업로드 중..." : "업로드하기")
                }
            }
            .buttonStyle(PillButtonStyle(kind: .solid))
            .disabled(!scanner.canExportJSON || scanner.isUploadingToBackend)

            Button {
                shareJSON()
            } label: {
                Text("JSON 공유")
            }
            .buttonStyle(LinkButtonStyle())
            .disabled(!scanner.canExportJSON)
        }
        .padding(20)
        .background(Color.appCream)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.appBorder), alignment: .top)
    }

    private var manualInputCard: some View {
        VStack(spacing: 12) {
            Text("방 크기 직접 입력")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.appInk)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                measurementField(title: "너비", text: $manualWidth)
                measurementField(title: "깊이", text: $manualDepth)
                measurementField(title: "높이", text: $manualHeight)
            }

            Button {
                scanner.createManualRoomJSON(
                    widthText: manualWidth,
                    depthText: manualDepth,
                    heightText: manualHeight
                )
            } label: {
                Label("방 데이터 생성", systemImage: "square.and.pencil")
            }
            .buttonStyle(PillButtonStyle(kind: .ghost))
        }
        .padding(16)
        .background(Color.appCard, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.appBorder, lineWidth: 1))
    }

    private func measurementField(title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.appInkSoft)

            TextField(title, text: text)
                .textFieldStyle(.plain)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(Color.appCream, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.appBorder, lineWidth: 1))
                .keyboardType(.decimalPad)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func jsonPreview(_ text: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.appInk)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        // Capped so the JSON panel can never grow past this and push the camera/3D
        // preview off screen — it scrolls internally instead of expanding indefinitely.
        .frame(maxWidth: .infinity, maxHeight: 220, alignment: .leading)
        .background(Color.appCard, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.appBorder, lineWidth: 1))
    }

    private func shareJSON() {
        do {
            shareURL = try scanner.exportJSON()
            isShowingShareSheet = true
        } catch {
            scanner.showError(error)
        }
    }
}

private struct HomeView: View {
    let isRoomPlanSupported: Bool
    @ObservedObject var uploadHistory: UploadedRoomStore
    let onStart: () -> Void
    @State private var selectedRecord: UploadedRoomRecord?
    @State private var recordPendingDelete: UploadedRoomRecord?

    var body: some View {
        Group {
            if uploadHistory.records.isEmpty {
                // Nothing to list yet — center the header+button as a group
                // instead of pinning it to the top with empty space below.
                VStack(spacing: 28) {
                    topNav
                    Spacer()
                    heroHeading
                    Spacer()
                }
                .padding(.horizontal, 24)
            } else {
                VStack(alignment: .leading, spacing: 22) {
                    topNav
                        .padding(.top, 6)
                    heading
                    roomsGrid
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appCream.ignoresSafeArea())
        .sheet(item: $selectedRecord) { record in
            RoomDetailView(
                record: record,
                modelURL: uploadHistory.modelURL(for: record),
                thumbnail: uploadHistory.thumbnailImage(for: record)
            )
        }
        .confirmationDialog(
            "이 방을 목록에서 삭제하시겠습니까?",
            isPresented: Binding(
                get: { recordPendingDelete != nil },
                set: { if !$0 { recordPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                if let recordPendingDelete {
                    uploadHistory.delete(recordPendingDelete)
                }
                recordPendingDelete = nil
            }
            Button("취소", role: .cancel) { recordPendingDelete = nil }
        }
    }

    // MARK: - Nav

    private var topNav: some View {
        HStack {
            Text("RoomFit")
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(Color.appInk)

            Spacer()

            Button(action: onStart) {
                Text(isRoomPlanSupported ? "스캔 시작" : "시작하기")
            }
            .buttonStyle(PillButtonStyle(kind: .solid, isBlock: false))
        }
    }

    // MARK: - Empty state

    private var heroHeading: some View {
        VStack(spacing: 12) {
            IsometricRoomGlyph()
                .frame(width: 88, height: 72)

            Text("아직 스캔한 방이 없어요")
                .font(.system(size: 24, weight: .heavy))
                .multilineTextAlignment(.center)

            Text(
                isRoomPlanSupported
                    ? "스캐너를 통해 당신의 방을 3D 데이터로 저장하세요"
                    : "이 기기는 카메라 스캔을 지원하지 않아 방 크기를 직접 입력할 수 있어요"
            )
            .font(.system(size: 14))
            .foregroundStyle(Color.appInkSoft)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Room list state

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("스캔한 공간을\n확인하세요")
                .font(.system(size: 24, weight: .heavy))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            Text("업로드한 방을 다시 보거나, 새로운 공간을 스캔해보세요.")
                .font(.system(size: 13))
                .foregroundStyle(Color.appInkSoft)
        }
    }

    private let gridColumns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var roomsGrid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 12) {
                ForEach(uploadHistory.records) { record in
                    roomCard(record)
                }
            }
            .padding(.bottom, 24)
        }
    }

    private func roomCard(_ record: UploadedRoomRecord) -> some View {
        Button {
            selectedRecord = record
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                thumbnailView(record)
                    .frame(height: 84)
                    .frame(maxWidth: .infinity)
                    .background(Color.appFloor)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                Text(record.name)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.appInk)
                    .lineLimit(1)

                Text(record.uploadedAt, style: .date)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appInkSoft)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appCard, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.appBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                recordPendingDelete = record
            } label: {
                Label("삭제", systemImage: "trash")
            }
        }
    }

    private func thumbnailView(_ record: UploadedRoomRecord) -> some View {
        Group {
            if let image = uploadHistory.thumbnailImage(for: record) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                IsometricRoomGlyph()
            }
        }
    }
}

/// Shown when a list row is tapped — an interactive 3D preview of the exported
/// USDZ if one exists, otherwise the saved thumbnail as a fallback (mock/manual
/// rooms have no CapturedRoom to export, and a model export can also just fail).
private struct RoomDetailView: View {
    let record: UploadedRoomRecord
    let modelURL: URL?
    let thumbnail: UIImage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let modelURL {
                    RoomModelPreview(url: modelURL)
                } else if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .padding()
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 48))
                            .foregroundStyle(Color.appInkSoft)
                        Text("저장된 미리보기가 없습니다.")
                            .foregroundStyle(Color.appInkSoft)
                    }
                }
            }
            .navigationTitle(record.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
    }
}
