import SwiftUI

struct SetupView: View {
    @Bindable var vm: ConversationViewModel

    var body: some View {
        VStack(spacing: 16) {
            Text("준비 확인").font(.largeTitle.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
            ScrollView {
            VStack(spacing: 0) {
                ForEach(vm.readiness) { item in
                    HStack {
                        Text(item.kind.title).font(.title3)
                        Spacer()
                        if item.isReady {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.readyGreen).font(.title)
                        } else if item.isDownloading {
                            ProgressView()
                        } else {
                            Button { vm.download(item) } label: {
                                Image(systemName: "arrow.down.circle.fill").font(.title).foregroundStyle(Color.seal)
                            }
                            .accessibilityLabel("\(item.kind.title) 다운로드")
                        }
                    }
                    .frame(minHeight: 64)
                    Divider().overlay(Color.hairline)
                }
            }
            }
            Button { vm.completeSetup() } label: {
                Text("시작하기").font(.title3.weight(.semibold))
                    .foregroundStyle(vm.allReady ? Color.inkOn : Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(vm.allReady ? Color.ink : Color.surface, in: .rect(cornerRadius: 16))
            }
            .disabled(!vm.allReady)
        }
        .padding(16)
    }
}

#Preview {
    let vm = ConversationViewModel()
    vm.readiness[kind: .microphone].isReady = true
    vm.readiness[kind: .speechPermission].isReady = true
    vm.readiness[kind: .zhModel].isDownloading = true
    return SetupView(vm: vm)
}

#Preview("가로", traits: .landscapeLeft) {
    let vm = ConversationViewModel()
    vm.readiness[kind: .microphone].isReady = true
    vm.readiness[kind: .zhModel].isDownloading = true
    return SetupView(vm: vm)
}
