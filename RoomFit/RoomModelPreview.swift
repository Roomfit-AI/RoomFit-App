import SceneKit
import SwiftUI

/// Renders a room's exported USDZ directly with SceneKit rather than
/// QLPreviewController. QuickLook frames the model with a lot of margin and
/// exposes no API to change that starting distance, which meant every model
/// opened looking small until the user manually pinch-zoomed — this instead
/// places the initial camera close enough to read as "zoomed in" right away,
/// while `allowsCameraControl` still gives free rotate/pinch/pan.
struct RoomModelPreview: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X

        if let scene = try? SCNScene(url: url, options: nil) {
            frameCamera(in: scene)
            view.scene = scene
        }
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    /// Positions a camera at roughly 1.5x the model's bounding radius, isometric
    /// angle — noticeably closer than QuickLook's own default framing.
    private func frameCamera(in scene: SCNScene) {
        let (minVec, maxVec) = scene.rootNode.boundingBox
        let center = SCNVector3(
            (minVec.x + maxVec.x) / 2,
            (minVec.y + maxVec.y) / 2,
            (minVec.z + maxVec.z) / 2
        )
        let extent = SCNVector3(maxVec.x - minVec.x, maxVec.y - minVec.y, maxVec.z - minVec.z)
        let radius: Float = max(extent.x, max(extent.y, extent.z)) / 2
        guard radius > 0 else { return }

        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.zNear = 0.01
        camera.zFar = Double(radius) * 20
        cameraNode.camera = camera

        let distance = Double(radius) * 1.5
        let angle = Double.pi / 4
        let offsetX: Float = Float(distance * sin(angle))
        let offsetY: Float = Float(distance * 0.55)
        let offsetZ: Float = Float(distance * cos(angle))
        cameraNode.position = SCNVector3(center.x + offsetX, center.y + offsetY, center.z + offsetZ)
        cameraNode.look(at: center)
        scene.rootNode.addChildNode(cameraNode)
    }
}
