import RoomPlan
import SwiftUI

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
    }

    static func dismantleUIView(_ uiView: RoomCaptureView, coordinator: Coordinator) {
        uiView.captureSession.stop()
    }

    final class Coordinator {
        let captureView = RoomCaptureView(frame: .zero)

        init() {
            captureView.isModelEnabled = true
        }
    }
}
