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

            VStack {
                HStack {
                    backToHomeButton
                    Spacer()
                }
                Spacer()
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            bottomBar
        }
        .onAppear {
            if scanner.phase == .idle {
                scanner.startScan()
            }
        }
    }

    private var backToHomeButton: some View {
        Button {
            requestGoHome()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.5), in: Circle())
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
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("홈으로") { screen = .home }
                        .foregroundStyle(.white.opacity(0.8))
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
        Label(scanner.statusText, systemImage: "dot.radiowaves.left.and.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.5), in: Capsule())
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
    /// the 3D room preview.
    private var scanningBar: some View {
        Button(role: .destructive) {
            scanner.stopScan()
        } label: {
            Label("스캔 멈추기", systemImage: "stop.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .padding()
        .background(.ultraThinMaterial)
    }

    private var completedBar: some View {
        VStack(spacing: 12) {
            if let uploadMessage = scanner.uploadMessage {
                Text(uploadMessage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(uploadMessage.hasPrefix("업로드 완료") ? .green : .red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            roomNameField

            primaryActions

            goHomeButton

            Button {
                shareJSON()
            } label: {
                Label("JSON 공유", systemImage: "square.and.arrow.up")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!scanner.canExportJSON)
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private var roomNameField: some View {
        TextField("방 이름을 입력하세요 (예: 우리집 거실)", text: $roomName)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity)
    }

    /// Upload + Rescan are the two actions users need after a scan.
    private var primaryActions: some View {
        HStack(spacing: 12) {
            Button {
                scanner.uploadJSONToBackend(name: roomName)
            } label: {
                HStack {
                    if scanner.isUploadingToBackend {
                        ProgressView()
                    } else {
                        Image(systemName: "icloud.and.arrow.up")
                    }
                    Text(scanner.isUploadingToBackend ? "업로드 중..." : "업로드하기")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!scanner.canExportJSON || scanner.isUploadingToBackend)

            Button {
                requestRescan()
            } label: {
                Label("다시 스캔하기", systemImage: "arrow.counterclockwise")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .labelStyle(.titleAndIcon)
    }

    /// Explicitly bigger than the two actions above it, per feedback that the
    /// previous small text-link "홈으로" was too easy to miss.
    private var goHomeButton: some View {
        Button {
            requestGoHome()
        } label: {
            Label("홈으로", systemImage: "house.fill")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        // `.tint(.secondary)` rendered the border/text gray, which read as a
        // disabled button — use the standard accent tint instead.
    }

    // MARK: - Unsupported-device flow (manual entry)

    private var unsupportedView: some View {
        ZStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 16) {
                        Image(systemName: "iphone.slash")
                            .font(.system(size: 42, weight: .semibold))
                            .foregroundStyle(.secondary)

                        Text("이 기기에서는 RoomPlan을 지원하지 않습니다.")
                            .font(.headline)

                        Text("테스트용 방 데이터를 만들거나, 방 크기를 직접 입력해 JSON을 생성할 수 있습니다.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        Button {
                            scanner.generateMockRoomJSON()
                        } label: {
                            Label("테스트용 방 데이터 생성", systemImage: "curlybraces")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

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
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .background(Color(.secondarySystemBackground), in: Circle())
                    }
                    Spacer()
                }
                Spacer()
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private var unsupportedExportBar: some View {
        VStack(spacing: 12) {
            if let uploadMessage = scanner.uploadMessage {
                Text(uploadMessage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(uploadMessage.hasPrefix("업로드 완료") ? .green : .red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            roomNameField

            Button {
                scanner.uploadJSONToBackend(name: roomName)
            } label: {
                HStack {
                    if scanner.isUploadingToBackend {
                        ProgressView()
                    } else {
                        Image(systemName: "icloud.and.arrow.up")
                    }
                    Text(scanner.isUploadingToBackend ? "업로드 중..." : "업로드하기")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!scanner.canExportJSON || scanner.isUploadingToBackend)
            .labelStyle(.titleAndIcon)

            Button {
                shareJSON()
            } label: {
                Label("JSON 공유", systemImage: "square.and.arrow.up")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!scanner.canExportJSON)
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private var manualInputCard: some View {
        VStack(spacing: 12) {
            Text("방 크기 직접 입력")
                .font(.headline)
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
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private func measurementField(title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.decimalPad)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func jsonPreview(_ text: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        // Capped so the JSON panel can never grow past this and push the camera/3D
        // preview off screen — it scrolls internally instead of expanding indefinitely.
        .frame(maxWidth: .infinity, maxHeight: 220, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
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
                    Spacer()
                    headerSection
                    startButton
                    Spacer()
                }
                .padding(.horizontal, 24)
            } else {
                VStack(spacing: 28) {
                    headerSection
                        .padding(.top, 40)
                    startButton
                    uploadedRoomsSection
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
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

    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "cube.transparent.fill")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.tint)

            Text("RoomFit Scanner")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)

            Text(
                isRoomPlanSupported
                    ? "3D 데이터로 저장하세요"
                    : "이 기기는 카메라 스캔을 지원하지 않아 방 크기를 직접 입력할 수 있어요"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
        }
    }

    private var startButton: some View {
        Button(action: onStart) {
            Label(isRoomPlanSupported ? "스캔 시작하기" : "시작하기", systemImage: "play.fill")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private var uploadedRoomsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("업로드한 방")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(uploadHistory.records) { record in
                        uploadedRoomRow(record)

                        if record.id != uploadHistory.records.last?.id {
                            Divider().padding(.leading, 68)
                        }
                    }
                }
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func uploadedRoomRow(_ record: UploadedRoomRecord) -> some View {
        HStack(spacing: 4) {
            Button {
                selectedRecord = record
            } label: {
                HStack(spacing: 12) {
                    thumbnailView(record)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)

                        Text(record.uploadedAt, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                recordPendingDelete = record
            } label: {
                Image(systemName: "trash")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .padding(10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func thumbnailView(_ record: UploadedRoomRecord) -> some View {
        Group {
            if let image = uploadHistory.thumbnailImage(for: record) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color(.tertiarySystemBackground)
                    Image(systemName: "cube.transparent")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
                            .foregroundStyle(.secondary)
                        Text("저장된 미리보기가 없습니다.")
                            .foregroundStyle(.secondary)
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
