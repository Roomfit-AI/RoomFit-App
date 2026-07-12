import SwiftUI
import UIKit

/// Design tokens ported from the approved ROOMAI-inspired direction: warm
/// ivory surfaces, near-black ink, and two muted accent hues used only for
/// decorative room-glyph illustration (never for structural UI, which stays
/// monochrome black/white/cream by design).
extension Color {
    static let appInk = Color(hex: 0x14120F)
    static let appInkSoft = Color(hex: 0x6E6A5E)
    static let appCream = Color(hex: 0xF7F4EC)
    static let appCard = Color.white
    static let appBorder = Color(hex: 0xE7E1D2)
    static let appWood = Color(hex: 0xB98A5A)
    static let appWoodDim = Color(hex: 0xD8B389)
    static let appSage = Color(hex: 0x7C8567)
    static let appSageDim = Color(hex: 0xB7BFA6)
    static let appFloor = Color(hex: 0xEFE7D6)

    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// Black-fill/cream-text "solid" pill for primary actions, or a white-fill
/// bordered "ghost" pill for secondary ones — the two button voices used
/// throughout the approved direction.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case solid, ghost }

    var kind: Kind = .solid
    var isBlock: Bool = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold))
            .frame(maxWidth: isBlock ? .infinity : nil)
            .padding(.vertical, 14)
            .padding(.horizontal, 22)
            .background(kind == .solid ? Color.appInk : Color.appCard)
            .foregroundStyle(kind == .solid ? Color.appCream : Color.appInk)
            .overlay(
                Capsule().stroke(kind == .ghost ? Color.appBorder : .clear, lineWidth: 1)
            )
            .clipShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.4)
    }
}

/// Small text-only "link" button (e.g. "홈으로", "JSON 공유") — no fill, just
/// weight + tap feedback.
struct LinkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color.appInkSoft)
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
    }
}

/// Rounds only the given corners — `UnevenRoundedRectangle` needs iOS 17,
/// this app's deployment target is iOS 16.
struct RoundedCorner: Shape {
    var radius: CGFloat = 20
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

/// Simple isometric-room hexagon used as a placeholder thumbnail for rooms
/// without a captured 3D snapshot (e.g. mock/manual entries).
struct IsometricRoomGlyph: View {
    var accent: Color = .appWood
    var accentDim: Color = .appWoodDim

    private struct Facet: Shape {
        let points: [CGPoint]
        func path(in rect: CGRect) -> Path {
            var path = Path()
            guard let first = points.first else { return path }
            path.move(to: CGPoint(x: rect.minX + first.x * rect.width, y: rect.minY + first.y * rect.height))
            for point in points.dropFirst() {
                path.addLine(to: CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height))
            }
            path.closeSubpath()
            return path
        }
    }

    var body: some View {
        ZStack {
            Facet(points: [
                CGPoint(x: 0.5, y: 0.11), CGPoint(x: 0.9, y: 0.39),
                CGPoint(x: 0.5, y: 0.67), CGPoint(x: 0.1, y: 0.39)
            ]).fill(Color.appFloor)

            Facet(points: [
                CGPoint(x: 0.1, y: 0.39), CGPoint(x: 0.5, y: 0.67),
                CGPoint(x: 0.5, y: 0.96), CGPoint(x: 0.1, y: 0.68)
            ]).fill(accentDim)

            Facet(points: [
                CGPoint(x: 0.9, y: 0.39), CGPoint(x: 0.5, y: 0.67),
                CGPoint(x: 0.5, y: 0.96), CGPoint(x: 0.9, y: 0.68)
            ]).fill(accent)
        }
    }
}
