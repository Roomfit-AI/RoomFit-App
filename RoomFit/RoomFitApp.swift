import SwiftUI

@main
struct RoomFitApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                // The new visual direction is a fixed warm-ivory/black brand
                // palette (custom Color(hex:) tokens), not semantic system
                // colors — locking to light keeps native chrome (keyboard,
                // alerts, status bar) consistent with it instead of clashing
                // under system dark mode.
                .preferredColorScheme(.light)
        }
    }
}
