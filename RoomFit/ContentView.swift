import RoomPlan
import SwiftUI

struct ContentView: View {
    @StateObject private var scanner = RoomScanController()
    @State private var shareURL: URL?
    @State private var isShowingShareSheet = false
    @State private var manualWidth = "3.2"
    @State private var manualDepth = "4.5"
    @State private var manualHeight = "2.4"

    var body: some View {
        Group {
            if RoomCaptureSession.isSupported {
                scannerView
            } else {
                unsupportedView
            }
        }
        .sheet(isPresented: $isShowingShareSheet) {
            if let shareURL {
                ShareSheet(activityItems: [shareURL])
            }
        }
    }

    private var scannerView: some View {
        ZStack {
            RoomCaptureViewContainer(scanner: scanner)
                .ignoresSafeArea()

            VStack {
                statusBanner
                Spacer()
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                if let jsonPreviewText = scanner.jsonPreviewText {
                    jsonPreview(jsonPreviewText)
                }

                controls
            }
                .padding()
                .background(.ultraThinMaterial)
        }
    }

    private var statusBanner: some View {
        Text(scanner.statusText)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var controls: some View {
        VStack(spacing: 12) {
            scanControls
            exportControls
        }
        .labelStyle(.titleAndIcon)
    }

    private var scanControls: some View {
        HStack(spacing: 12) {
            Button {
                scanner.startScan()
            } label: {
                Label("Start Scan", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(scanner.isScanning)

            Button(role: .destructive) {
                scanner.stopScan()
            } label: {
                Label("Stop Scan", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!scanner.isScanning)
        }
    }

    private var exportControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    scanner.saveJSON()
                } label: {
                    Label("Save JSON", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!scanner.canExportJSON)

                Button {
                    shareJSON()
                } label: {
                    Label("Share JSON", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!scanner.canExportJSON)
            }

            Button {
                scanner.uploadJSONToBackend()
            } label: {
                HStack {
                    if scanner.isUploadingToBackend {
                        ProgressView()
                    } else {
                        Image(systemName: "icloud.and.arrow.up")
                    }
                    Text(scanner.isUploadingToBackend ? "Uploading..." : "Upload to Backend")
                }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!scanner.canExportJSON || scanner.isUploadingToBackend)

            if let uploadMessage = scanner.uploadMessage {
                Text(uploadMessage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(uploadMessage.hasPrefix("Uploaded.") ? .green : .red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var unsupportedView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: "iphone.slash")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text("RoomPlan is not supported on this device.")
                        .font(.headline)

                    Text("Use a mock room or enter room dimensions manually to create RoomFit JSON.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Button {
                        scanner.generateMockRoomJSON()
                    } label: {
                        Label("Generate Mock Room JSON", systemImage: "curlybraces")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    manualInputCard

                    if let jsonPreviewText = scanner.jsonPreviewText {
                        jsonPreview(jsonPreviewText)
                    }
                }
                .padding()
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }

            exportControls
                .labelStyle(.titleAndIcon)
                .padding()
                .background(.ultraThinMaterial)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private var manualInputCard: some View {
        VStack(spacing: 12) {
            Text("Manual Room Input")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                measurementField(title: "Width", text: $manualWidth)
                measurementField(title: "Depth", text: $manualDepth)
                measurementField(title: "Height", text: $manualHeight)
            }

            Button {
                scanner.createManualRoomJSON(
                    widthText: manualWidth,
                    depthText: manualDepth,
                    heightText: manualHeight
                )
            } label: {
                Label("Create Room JSON", systemImage: "square.and.pencil")
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
