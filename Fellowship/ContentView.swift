import SwiftUI

struct ContentView: View {
    @State private var vm = ConversationViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if vm.showSetup { SetupView(vm: vm) } else { ConversationView(vm: vm) }
        }
        .onChange(of: vm.showSetup, initial: true) { vm.showSetup ? vm.stop() : vm.start() }
        .onChange(of: scenePhase) { scenePhase == .active ? vm.refreshReadiness() : vm.cancelPress() }
    }
}

#Preview {
    ContentView()
}
