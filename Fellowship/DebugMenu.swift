#if DEBUG
import SwiftUI

struct DebugMenu: View {
    @Bindable var vm: ConversationViewModel

    var body: some View {
        Menu {
            Button(vm.earphonesConnected ? "이어폰 빠짐" : "이어폰 꽂음") {
                vm.earphonesConnected ? vm.simulateUnplug() : vm.simulateReplug()
            }
            Button("다음 인식 실패") { vm.simulateRecognitionFailure() }
            Button("언어 데이터 없음") { vm.simulateMissingLanguageData() }
            Button("문장 밀림") { vm.simulateBacklog() }
            Button("준비 화면 초기화", role: .destructive) { vm.resetSetup() }
        } label: {
            Image(systemName: "ladybug").font(.title3)
        }
    }
}

#Preview {
    DebugMenu(vm: ConversationViewModel())
}
#endif
