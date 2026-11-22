import SwiftUI

struct ContentView: View {
    @State private var vm = ConversationViewModel()
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG
    @State private var showProbe = ProcessInfo.processInfo.arguments.contains("-probe")
    #endif

    var body: some View {
        Group {
            if vm.showSetup { SetupView(vm: vm) } else { ConversationView(vm: vm) }
        }
        .onChange(of: vm.showSetup, initial: true) { vm.showSetup ? vm.stop() : vm.start() }
        #if DEBUG
        .sheet(isPresented: $showProbe) { EngineProbeView(autoRun: true) }
        #endif
        .onChange(of: scenePhase) { scenePhase == .active ? vm.refreshReadiness() : vm.cancelPress() }
    }
}

#Preview {
    ContentView()
}
