import SwiftUI
import Translation

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
        .translationTask(vm.translationRequest) { session in
            // The SDK hands a MainActor session to a @concurrent closure; same escape hatch as the verified probe.
            nonisolated(unsafe) let s = session
            do { try await s.prepareTranslation(); vm.translationPrepared(ok: true) }
            catch { vm.translationPrepared(ok: false) }
        }
        .sheet(isPresented: $vm.showVoiceHelp) { voiceHelp }
    }

    private var voiceHelp: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("한국어 고품질 음성 받기").font(.title2.weight(.semibold))
            Text("1. 설정 → 손쉬운 사용 → 읽기 및 말하기\n2. 음성 → 한국어\n3. 고품질 음성 다운로드\n\n다운로드가 끝나면 이 앱으로 돌아오세요.")
                .font(.title3)
            Spacer()
            Button { vm.showVoiceHelp = false } label: {
                Text("확인").font(.title3.weight(.semibold)).foregroundStyle(Color.inkOn)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(Color.ink, in: .rect(cornerRadius: 16))
            }
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}

#Preview {
    let vm = ConversationViewModel.preview()
    vm.readiness[kind: .microphone].isReady = true
    vm.readiness[kind: .speechPermission].isReady = true
    vm.readiness[kind: .zhModel].isDownloading = true
    return SetupView(vm: vm)
}

#Preview("가로", traits: .landscapeLeft) {
    let vm = ConversationViewModel.preview()
    vm.readiness[kind: .microphone].isReady = true
    vm.readiness[kind: .zhModel].isDownloading = true
    return SetupView(vm: vm)
}
