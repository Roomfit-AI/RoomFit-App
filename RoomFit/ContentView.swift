import RoomPlan
import SwiftUI
import UIKit

private enum AppScreen {
    case home
    case scanning
}

/// The two ways a LiDAR-unsupported device can prepare a room to upload.
private enum UnsupportedMethod {
    case sampleRoom
    case manualInput
}

struct ContentView: View {
    @StateObject private var uploadHistory: UploadedRoomStore
    @StateObject private var scanner: RoomScanController
    @StateObject private var pairingCodeStore = ClientPairingCodeStore()
    @State private var screen: AppScreen = .home
    @State private var isShowingPairingCode = false
    @State private var shareURL: URL?
    @State private var isShowingShareSheet = false
    @State private var isShowingUnsavedRescanAlert = false
    @State private var isShowingUnsavedHomeAlert = false
    @State private var roomName = ""
    @State private var manualWidth = "3.2"
    @State private var manualDepth = "4.5"
    @State private var manualHeight = "2.4"
    @State private var selectedSample: SampleRoomKind?
    @State private var unsupportedMethod: UnsupportedMethod?
    @State private var showIntro = true

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
            if showIntro {
                introView
            } else {
                switch screen {
                case .home:
                    HomeView(
                        isRoomPlanSupported: isRoomPlanSupported,
                        uploadHistory: uploadHistory,
                        onStart: startFromHome,
                        onShowPairingCode: showPairingCode
                    )
                case .scanning:
                    if isRoomPlanSupported {
                        scannerView
                    } else {
                        unsupportedView
                    }
                }
            }
        }
        .task {
            // 앱 첫 실행 시 3초 동안만 보여주는 인트로 — 이후엔 다시 뜨지 않는다
            // (ContentView 자체가 최초 1번만 생성되는 루트 뷰라 `.task`도 1번만 실행됨).
            try? await Task.sleep(for: .seconds(3))
            withAnimation(.easeInOut(duration: 0.4)) {
                showIntro = false
            }
        }
        .sheet(isPresented: $isShowingShareSheet) {
            if let shareURL {
                ShareSheet(activityItems: [shareURL])
            }
        }
        .sheet(isPresented: $isShowingPairingCode) {
            PairingCodeSheetView(store: pairingCodeStore)
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

    // MARK: - Intro (3초 스플래시)

    private var introView: some View {
        VStack(spacing: 20) {
            Spacer()

            IsometricRoomGlyph()
                .frame(width: 96, height: 78)

            VStack(spacing: 10) {
                Text("ROOMFIT")
                    .font(.system(size: 34, weight: .heavy))
                    .foregroundStyle(Color.appInk)
                    .tracking(2)

                Text("당신만의 공간,\nAI가 완성해드립니다")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.appInkSoft)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appCream.ignoresSafeArea())
        .transition(.opacity)
    }

    private func startFromHome() {
        roomName = ""
        screen = .scanning
        // Don't call scanner.startScan() here — RoomCaptureViewContainer hasn't
        // been mounted yet at this point, so captureSession is still nil and
        // startScan() would bail out with "스캐너가 아직 준비되지 않았습니다."
        // scannerView's onAppear triggers the actual start once it's attached.
    }

    private func showPairingCode() {
        isShowingPairingCode = true
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
                // The raw capture view keeps rendering its frozen 3D mesh
                // underneath — cover it with the real completed layout so
                // the model preview fills this space properly instead of
                // leaving it as dead space above the bottom sheet.
                completedContent
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

    /// Fills the space above the bottom sheet — previously left as dead flat
    /// color once the raw capture view was hidden. A small heading plus the
    /// actual 3D model (rotate/zoom-able) balances that space instead of
    /// squeezing the preview into a small card down in the sheet.
    private var completedContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("스캔 완료")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(Color.appInk)
                Text("3D 모델을 확인해보세요")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appInkSoft)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            modelPreview
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.appCream.ignoresSafeArea())
    }

    /// The finished scan's actual 3D model (rotate/zoom-able), or a placeholder
    /// glyph if the export hasn't landed yet.
    private var modelPreview: some View {
        Group {
            if let modelURL = scanner.lastModelURL {
                RoomModelPreview(url: modelURL)
            } else {
                IsometricRoomGlyph()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appFloor)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.appBorder, lineWidth: 1))
    }

    private var completedBar: some View {
        VStack(spacing: 14) {
            if let uploadMessage = scanner.uploadMessage {
                Text(uploadMessage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(uploadMessage.hasPrefix("업로드 완료") ? Color.appSage : .red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            roomNameField

            primaryActions

            HStack(spacing: 20) {
                Button {
                    shareJSON()
                } label: {
                    Text("JSON 공유")
                }
                .buttonStyle(LinkButtonStyle())
                .disabled(!scanner.canExportJSON)

                Button {
                    shareDebugInfo()
                } label: {
                    Text("디버그 정보 공유")
                }
                .buttonStyle(LinkButtonStyle())
                .disabled(scanner.lastDebugInfo == nil)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(20)
        .background(Color.appCream)
        .clipShape(RoundedCorner(radius: 28, corners: [.topLeft, .topRight]))
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

            if scanner.canReopenWeb {
                Button {
                    openWeb()
                } label: {
                    Label("웹에서 보기", systemImage: "safari")
                }
                .buttonStyle(PillButtonStyle(kind: .ghost))
            }

            Button {
                showPairingCode()
            } label: {
                Label("컴퓨터에서 보기", systemImage: "desktopcomputer")
            }
            .buttonStyle(PillButtonStyle(kind: .ghost))

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

    /// Room 업로드 성공 후 "웹에서 보기"에서 호출한다 — 업로드 자체가 실패한
    /// 경우와 구분하기 위해, 여기서 실패하면(브라우저를 열 수 없는 등 드문 경우)
    /// scanner.uploadMessage를 별도 문구로 덮어써 "업로드는 끝났다"는 걸 분명히
    /// 한다.
    private func openWeb() {
        guard let url = scanner.webHandoffURL else { return }
        UIApplication.shared.open(url) { success in
            if !success {
                scanner.recordWebOpenFailure()
            }
        }
    }

    // MARK: - Unsupported-device flow (sample room or manual size entry)

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

                        Text("샘플룸 중 하나를 고르거나, 방 크기를 입력해 빈 방을 만들 수 있습니다.")
                            .font(.subheadline)
                            .foregroundStyle(Color.appInkSoft)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        unsupportedContent
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
        .onAppear {
            // Re-entering this screen (e.g. after uploading, tapping Home, and
            // starting again) should start from the choice screen, not show a
            // stale "준비 완료" summary left over from the previous visit.
            resetToChoice()
        }
    }

    /// Three states, mutually exclusive: pick a method, fill in that method's
    /// picker, or (once `scanner.phase == .completed`) show what's ready to
    /// upload — no raw JSON is ever shown here.
    @ViewBuilder
    private var unsupportedContent: some View {
        if scanner.phase == .completed {
            readySummaryCard
        } else if let unsupportedMethod {
            VStack(spacing: 16) {
                backToChoiceButton
                switch unsupportedMethod {
                case .sampleRoom:
                    sampleRoomSection
                case .manualInput:
                    manualInputCard
                }
            }
        } else {
            methodChoiceSection
        }
    }

    /// The top-level fork: sample room vs. manual size entry.
    private var methodChoiceSection: some View {
        VStack(spacing: 12) {
            methodChoiceCard(
                title: "샘플룸 사용",
                subtitle: "미리 준비된 방 2종 중 하나를 골라 그대로 업로드합니다.",
                icon: "square.stack.3d.up"
            ) {
                unsupportedMethod = .sampleRoom
            }

            methodChoiceCard(
                title: "방 크기 직접 입력",
                subtitle: "너비·깊이·높이를 입력한 크기의 빈 방을 만듭니다.",
                icon: "ruler"
            ) {
                unsupportedMethod = .manualInput
            }
        }
    }

    private func methodChoiceCard(title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.appInk)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.appInk)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appInkSoft)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.appInkSoft)
            }
            .padding(16)
            .background(Color.appCard, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.appBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var backToChoiceButton: some View {
        Button {
            unsupportedMethod = nil
            selectedSample = nil
        } label: {
            Label("다른 방법 선택", systemImage: "chevron.left")
        }
        .buttonStyle(LinkButtonStyle())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Shown once a sample room or manual size has produced room data —
    /// a plain-language summary instead of the raw JSON.
    private var readySummaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.appSage)
                Text("방 데이터 준비 완료")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.appInk)
            }

            Text(readySummaryText)
                .font(.system(size: 13))
                .foregroundStyle(Color.appInkSoft)

            Button {
                resetToChoice()
            } label: {
                Label("다시 선택하기", systemImage: "arrow.uturn.left")
            }
            .buttonStyle(LinkButtonStyle())
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appCard, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.appBorder, lineWidth: 1))
    }

    private var readySummaryText: String {
        if let selectedSample {
            return "선택한 샘플룸: \(selectedSample.displayName)"
        }
        return "직접 입력한 빈 방 크기: \(manualWidth) x \(manualDepth) x \(manualHeight) m"
    }

    private func resetToChoice() {
        unsupportedMethod = nil
        selectedSample = nil
        scanner.resetPreparedRoom()
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

            if scanner.canReopenWeb {
                Button {
                    openWeb()
                } label: {
                    Label("웹에서 보기", systemImage: "safari")
                }
                .buttonStyle(PillButtonStyle(kind: .ghost))
            }

            Button {
                showPairingCode()
            } label: {
                Label("컴퓨터에서 보기", systemImage: "desktopcomputer")
            }
            .buttonStyle(PillButtonStyle(kind: .ghost))

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

    /// iPhone Pro가 아니라 RoomPlan 스캔이 안 되는 기기를 위한 대체 경로 — 실제 스캔
    /// JSON과 동일한 구조(벽/문/창문 포함)의 샘플룸 2종 중 하나를 골라 그대로 업로드할
    /// 수 있게 한다. 백엔드에 미리 시딩된 "가구가 있는 방"/"빈 방" 샘플과 같은 데이터.
    private var sampleRoomSection: some View {
        VStack(spacing: 12) {
            Text("샘플룸 선택")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.appInk)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                ForEach(SampleRoomKind.allCases) { kind in
                    sampleRoomCard(kind)
                }
            }
        }
        .padding(16)
        .background(Color.appCard, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.appBorder, lineWidth: 1))
    }

    private func sampleRoomCard(_ kind: SampleRoomKind) -> some View {
        let isSelected = selectedSample == kind

        return Button {
            selectedSample = kind
            scanner.loadSampleRoomJSON(kind)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: kind.iconName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.appCream : Color.appInk)

                Text(kind.displayName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isSelected ? Color.appCream : Color.appInk)

                Text(kind.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.appCream.opacity(0.8) : Color.appInkSoft)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.appInk : Color.appCream, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? Color.appInk : Color.appBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var manualInputCard: some View {
        VStack(spacing: 12) {
            Text("방 크기 직접 입력")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.appInk)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("입력한 크기의 빈 방(가구 없음)이 만들어집니다.")
                .font(.system(size: 12))
                .foregroundStyle(Color.appInkSoft)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                measurementField(title: "너비", text: $manualWidth)
                measurementField(title: "깊이", text: $manualDepth)
                measurementField(title: "높이", text: $manualHeight)
            }

            if scanner.statusText.hasPrefix("오류:") {
                Text(scanner.statusText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                selectedSample = nil
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

    private func shareJSON() {
        do {
            shareURL = try scanner.exportJSON()
            isShowingShareSheet = true
        } catch {
            scanner.showError(error)
        }
    }

    private func shareDebugInfo() {
        do {
            shareURL = try scanner.exportDebugInfo()
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
    let onShowPairingCode: () -> Void
    @State private var selectedRecord: UploadedRoomRecord?
    @State private var recordPendingDelete: UploadedRoomRecord?
    @State private var pendingPairingCodeRequest = false

    var body: some View {
        Group {
            if uploadHistory.records.isEmpty {
                // Nothing to list yet — center the header+button as a group
                // instead of pinning it to the top with empty space below.
                VStack(spacing: 28) {
                    topNav
                    Spacer()
                    heroHeading
                    startButton
                        .frame(maxWidth: 280)
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
        .sheet(item: $selectedRecord, onDismiss: {
            if pendingPairingCodeRequest {
                pendingPairingCodeRequest = false
                onShowPairingCode()
            }
        }) { record in
            RoomDetailView(
                record: record,
                uploadHistory: uploadHistory,
                onRequestPairingCode: { pendingPairingCodeRequest = true }
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
        HStack(spacing: 10) {
            Text("RoomFit")
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(Color.appInk)

            Spacer()

            Button(action: onShowPairingCode) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.appInkSoft)
                    .padding(10)
                    .background(Color.appCard, in: Circle())
                    .overlay(Circle().stroke(Color.appBorder, lineWidth: 1))
            }
            .accessibilityLabel("컴퓨터와 연결하기")

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

    private var startButton: some View {
        Button(action: onStart) {
            Label(isRoomPlanSupported ? "스캔 시작하기" : "시작하기", systemImage: "play.fill")
        }
        .buttonStyle(PillButtonStyle(kind: .solid))
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
                newScanCard
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

    private var newScanCard: some View {
        Button(action: onStart) {
            VStack(spacing: 8) {
                Circle()
                    .strokeBorder(Color.appInkSoft, lineWidth: 1.5)
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.appInkSoft)
                    )

                Text("새로 스캔하기")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.appInkSoft)
            }
            .frame(maxWidth: .infinity, minHeight: 140)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.appBorder, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            )
        }
        .buttonStyle(.plain)
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
/// Deliberately mirrors the just-scanned completed screen's layout (big preview
/// up top, name field + actions in a bottom sheet) so opening a saved room feels
/// like the same place, not a separate read-only viewer.
private struct RoomDetailView: View {
    let record: UploadedRoomRecord
    @ObservedObject var uploadHistory: UploadedRoomStore
    let onRequestPairingCode: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var editedName: String
    @State private var shareURL: URL?
    @State private var isShowingShareSheet = false
    @State private var isReuploading = false
    @State private var reuploadMessage: String?
    @State private var isShowingDeleteConfirm = false
    @State private var canReopenWeb = false

    init(record: UploadedRoomRecord, uploadHistory: UploadedRoomStore, onRequestPairingCode: @escaping () -> Void) {
        self.record = record
        self.uploadHistory = uploadHistory
        self.onRequestPairingCode = onRequestPairingCode
        _editedName = State(initialValue: record.name)
    }

    /// The record can be renamed while this sheet is open — re-read it from the
    /// store each time so the heading reflects the latest saved name.
    private var currentRecord: UploadedRoomRecord {
        uploadHistory.records.first { $0.id == record.id } ?? record
    }

    /// Only offered after a re-upload succeeds this session — mirrors the
    /// just-scanned flow, where "웹에서 보기" only appears once the current
    /// roomId is known to be live on the backend.
    private var webHandoffURL: URL? {
        BackendConfig.webHandoffURL(roomId: currentRecord.roomId, clientId: RoomFitClientIdentity.getOrCreateClientId())
    }

    private func openWeb() {
        guard let url = webHandoffURL else { return }
        UIApplication.shared.open(url)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(currentRecord.name)
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(Color.appInk)
                Text(currentRecord.uploadedAt, style: .date)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appInkSoft)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            preview
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.appCream.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { detailBar }
        .sheet(isPresented: $isShowingShareSheet) {
            if let shareURL {
                ShareSheet(activityItems: [shareURL])
            }
        }
    }

    private var preview: some View {
        Group {
            if let modelURL = uploadHistory.modelURL(for: currentRecord) {
                RoomModelPreview(url: modelURL)
            } else if let thumbnail = uploadHistory.thumbnailImage(for: currentRecord) {
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appFloor)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.appBorder, lineWidth: 1))
    }

    private var detailBar: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("방 이름")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.appInkSoft)
                    .textCase(.uppercase)
                    .tracking(0.4)

                TextField("방 이름", text: $editedName)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 14)
                    .background(Color.appCard, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.appBorder, lineWidth: 1))
            }

            if let reuploadMessage {
                Text(reuploadMessage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(reuploadMessage.hasPrefix("실패") ? .red : Color.appSage)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 10) {
                Button {
                    reuploadTapped()
                } label: {
                    HStack {
                        if isReuploading {
                            ProgressView().tint(Color.appCream)
                        } else {
                            Image(systemName: "icloud.and.arrow.up")
                        }
                        Text(isReuploading ? "업로드 중..." : "다시 업로드하기")
                    }
                }
                .buttonStyle(PillButtonStyle(kind: .solid))
                .disabled(isReuploading || uploadHistory.jsonURL(for: currentRecord) == nil)

                if canReopenWeb {
                    Button {
                        openWeb()
                    } label: {
                        Label("웹에서 보기", systemImage: "safari")
                    }
                    .buttonStyle(PillButtonStyle(kind: .ghost))
                }

                Button {
                    onRequestPairingCode()
                    dismiss()
                } label: {
                    Label("컴퓨터에서 보기", systemImage: "desktopcomputer")
                }
                .buttonStyle(PillButtonStyle(kind: .ghost))

                Button {
                    uploadHistory.rename(currentRecord, to: editedName)
                } label: {
                    Text("이름 저장")
                }
                .buttonStyle(PillButtonStyle(kind: .ghost))
                .disabled(editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    isShowingDeleteConfirm = true
                } label: {
                    Text("삭제").foregroundStyle(.red)
                }
                .buttonStyle(PillButtonStyle(kind: .ghost))
            }

            HStack(spacing: 20) {
                Button {
                    dismiss()
                } label: {
                    Text("닫기")
                }
                .buttonStyle(LinkButtonStyle())

                Button {
                    shareRecordJSON()
                } label: {
                    Text("JSON 공유")
                }
                .buttonStyle(LinkButtonStyle())
                .disabled(uploadHistory.jsonURL(for: currentRecord) == nil)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(20)
        .background(Color.appCream)
        .clipShape(RoundedCorner(radius: 28, corners: [.topLeft, .topRight]))
        .confirmationDialog(
            "이 방을 목록에서 삭제하시겠습니까?",
            isPresented: $isShowingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                uploadHistory.delete(currentRecord)
                dismiss()
            }
            Button("취소", role: .cancel) {}
        }
    }

    private func reuploadTapped() {
        guard !isReuploading else { return }
        uploadHistory.rename(currentRecord, to: editedName)
        isReuploading = true
        reuploadMessage = nil

        Task {
            do {
                try await uploadHistory.reupload(currentRecord)
                isReuploading = false
                reuploadMessage = "다시 업로드되었습니다."
                canReopenWeb = true
            } catch {
                isReuploading = false
                reuploadMessage = "실패: \(error.localizedDescription)"
            }
        }
    }

    private func shareRecordJSON() {
        guard let url = uploadHistory.jsonURL(for: currentRecord) else { return }
        shareURL = url
        isShowingShareSheet = true
    }
}
