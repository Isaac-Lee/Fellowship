import SwiftUI
import UIKit

@main
struct FellowshipApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup { ContentView() }
            .onChange(of: scenePhase, initial: true) {
                UIApplication.shared.isIdleTimerDisabled = (scenePhase == .active)
            }
    }
}
