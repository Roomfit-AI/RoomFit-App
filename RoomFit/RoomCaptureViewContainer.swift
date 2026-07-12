import RoomPlan
import SwiftUI
import UIKit

struct RoomCaptureViewContainer: UIViewRepresentable {
    @ObservedObject var scanner: RoomScanController

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> RoomCaptureView {
        let view = context.coordinator.captureView
        scanner.attach(view.captureSession)
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {
        // captureSession이 weak라서 해제됐을 수 있으니 재연결
        if scanner.needsReattach {
            scanner.attach(uiView.captureSession)
        }

        guard scanner.phase == .completed else {
            context.coordinator.isCapturingThumbnail = false
            return
        }

        guard scanner.lastThumbnail == nil, !context.coordinator.isCapturingThumbnail else { return }
        context.coordinator.isCapturingThumbnail = true

        Task { @MainActor in
            // Give RoomCaptureView a moment to finish drawing the processed 3D
            // mesh (isModelEnabled) before snapshotting it as the room thumbnail.
            try? await Task.sleep(for: .milliseconds(400))
            scanner.lastThumbnail = context.coordinator.snapshotImage()
        }
    }

    static func dismantleUIView(_ uiView: RoomCaptureView, coordinator: Coordinator) {
        uiView.captureSession.stop()
    }

    final class Coordinator {
        let captureView = RoomCaptureView(frame: .zero)
        var isCapturingThumbnail = false

        init() {
            captureView.isModelEnabled = true
        }

        func snapshotImage() -> UIImage? {
            let bounds = captureView.bounds
            guard bounds.width > 1, bounds.height > 1 else { return nil }

            let renderer = UIGraphicsImageRenderer(bounds: bounds)
            return renderer.image { _ in
                captureView.drawHierarchy(in: bounds, afterScreenUpdates: true)
            }
        }
    }
}
