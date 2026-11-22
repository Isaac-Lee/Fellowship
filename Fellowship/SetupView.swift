import SwiftUI

struct SetupView: View {
    @Bindable var vm: ConversationViewModel

    var body: some View {
        VStack(spacing: 16) {
            Text("준비 확인").font(.largeTitle.bold()).frame(maxWidth: .infinity, alignment: .leading)
            ScrollView {
            VStack(spacing: 0) {
                ForEach(vm.readiness) { item in
                    HStack {
                        Text(item.kind.title).font(.title3)
                        Spacer()
                        if item.isReady {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title)
                        } else if item.isDownloading {
                            ProgressView()
                        } else {
                            Button { vm.download(item) } label: {
                                Image(systemName: "arrow.down.circle.fill").font(.title)
                            }
                            .accessibilityLabel("\(item.kind.title) 다운로드")
                        }
                    }
                    .padding(.vertical, 14)
                    Divider()
                }
            }
            }
            Button("시작하기") { vm.completeSetup() }
                .font(.title2.bold())
                .frame(maxWidth: .infinity, minHeight: 56)
                .buttonStyle(.borderedProminent)
                .disabled(!vm.allReady)
        }
        .padding()
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
