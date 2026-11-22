import SwiftUI

struct ConversationView: View {
    @Bindable var vm: ConversationViewModel
    @Environment(\.verticalSizeClass) private var vSize
    private var landscape: Bool { vSize == .compact }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if vm.showUnpluggedBanner {
                Text("이어폰이 빠져서 음성을 껐어요")
                    .font(.headline).foregroundStyle(.black)
                    .frame(maxWidth: .infinity).padding(landscape ? 4 : 10)
                    .background(Color.yellow)
            }
            if landscape {
                HStack(spacing: 0) {
                    messageList
                    talkArea.containerRelativeFrame(.horizontal) { w, _ in w * 0.38 }
                }
            } else {
                messageList
                talkArea
            }
        }
        .sensoryFeedback(.impact, trigger: vm.isHoldingToTalk) { _, now in now }
        .sensoryFeedback(.success, trigger: vm.successCount)
        .onChange(of: landscape) { vm.cancelPress() }
        .fullScreenCover(item: $vm.showCard) { ShowCardView(message: $0) }
        .animation(.default, value: vm.showUnpluggedBanner)
    }

    private var topBar: some View {
        HStack {
            Text(vm.earphonesConnected ? "🎧 이어폰 연결됨" : "🎧 이어폰 연결 안 됨").font(.headline)
            Spacer()
            #if DEBUG
            Text("속도 \(vm.speechRate, specifier: "%.2f") · 대기 \(vm.pendingSpeechCount)")
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            DebugMenu(vm: vm)
            #endif
            Toggle("음성 끄기", isOn: Binding(get: { !vm.voiceEnabled }, set: { vm.voiceEnabled = !$0 }))
                .fixedSize()
        }
        .padding(.horizontal).padding(.vertical, landscape ? 2 : 8)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(vm.messages) { m in
                        bubble(m).onTapGesture {
                            m.speaker == .partner ? vm.replay(m) : (vm.showCard = m)
                        }
                    }
                    if let p = vm.partnerPartial {
                        Text(p).font(.title3).foregroundStyle(.secondary)
                            .padding(12).background(.quaternary, in: .rect(cornerRadius: 16))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .onChange(of: vm.messages.count) { withAnimation { proxy.scrollTo("bottom") } }
            .onChange(of: vm.partnerPartial) { proxy.scrollTo("bottom") }
        }
    }

    private func bubble(_ m: Message) -> some View {
        let mine = m.speaker == .me
        return VStack(alignment: .leading, spacing: 4) {
            Text(m.original).font(.footnote).foregroundStyle(mine ? Color.white.opacity(0.8) : .secondary)
            Text(m.translation).font(.title2.weight(.semibold))
        }
        .foregroundStyle(mine ? Color.white : .primary)
        .padding(12)
        .background(mine ? AnyShapeStyle(Color.blue) : AnyShapeStyle(.quaternary), in: .rect(cornerRadius: 16))
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    private var talkArea: some View {
        VStack(spacing: 8) {
            if landscape { Spacer(minLength: 0) }
            if vm.retryHint { Text("다시 말해 주세요").font(.headline).foregroundStyle(.orange) }
            if vm.isHoldingToTalk {
                Text("● 듣는 중…").font(.headline).foregroundStyle(.red)
                Text(vm.myPartial).font(.title3).foregroundStyle(.secondary).frame(minHeight: 28)
                    .lineLimit(landscape ? 3 : nil)
            }
            Text(vm.isHoldingToTalk ? "손을 떼면 번역해요" : "🎤 누르고 말하기")
                .font(.title.bold()).foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 88, maxHeight: landscape ? .infinity : 88)
                .background(vm.isHoldingToTalk ? Color.red : Color.blue, in: .rect(cornerRadius: 24))
                .onLongPressGesture(minimumDuration: .infinity, maximumDistance: 200, perform: {},
                                    onPressingChanged: { $0 ? vm.pressBegan() : vm.pressEnded() })
                .accessibilityLabel("누르고 말하기")
        }
        .padding()
        .animation(.default, value: vm.isHoldingToTalk)
        .animation(.default, value: vm.retryHint)
    }
}

#Preview {
    let vm = ConversationViewModel()
    vm.messages = [
        Message(speaker: .partner, original: "歡迎光臨！請問幾位？", translation: "어서 오세요! 몇 분이세요?"),
        Message(speaker: .me, original: "화장실이 어디예요?", translation: "請問洗手間在哪裡？"),
    ]
    vm.partnerPartial = "這邊請，菜單"
    vm.earphonesConnected = false
    vm.showUnpluggedBanner = true
    return ConversationView(vm: vm)
}

#Preview("가로", traits: .landscapeLeft) {
    let vm = ConversationViewModel()
    vm.messages = [
        Message(speaker: .partner, original: "歡迎光臨！請問幾位？", translation: "어서 오세요! 몇 분이세요?"),
        Message(speaker: .me, original: "화장실이 어디예요?", translation: "請問洗手間在哪裡？"),
    ]
    vm.partnerPartial = "這邊請，菜單"
    vm.showUnpluggedBanner = true
    return ConversationView(vm: vm)
}
