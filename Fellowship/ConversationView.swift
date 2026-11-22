import SwiftUI

struct ConversationView: View {
    @Bindable var vm: ConversationViewModel
    @Environment(\.verticalSizeClass) private var vSize
    private var landscape: Bool { vSize == .compact }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().overlay(Color.hairline)
            if vm.showUnpluggedBanner {
                Text("이어폰이 빠져서 음성을 껐어요")
                    .font(.subheadline.weight(.medium)).foregroundStyle(Color.amberText)
                    .frame(maxWidth: .infinity).padding(.vertical, landscape ? 4 : 8)
                    .background(Color.amberBanner)
            }
            if landscape {
                HStack(spacing: 0) {
                    messageList
                    HStack(spacing: 0) {
                        Rectangle().fill(Color.hairline).frame(width: 1)
                        talkArea.background(Color.surface)
                    }
                    .containerRelativeFrame(.horizontal) { w, _ in w * 0.22 }
                }
            } else {
                messageList
                Divider().overlay(Color.hairline)
                talkArea.background(Color.surface)
            }
        }
        .background(Color(.systemBackground))
        .sensoryFeedback(.impact, trigger: vm.isHoldingToTalk) { _, now in now }
        .sensoryFeedback(.success, trigger: vm.successCount)
        .onChange(of: landscape) { vm.cancelPress() }
        .fullScreenCover(item: $vm.showCard) { ShowCardView(message: $0) }
        .animation(.default, value: vm.showUnpluggedBanner)
    }

    private var topBar: some View {
        HStack {
            Text(vm.earphonesConnected ? "🎧 이어폰 연결됨" : "🎧 이어폰 연결 안 됨").font(.subheadline.weight(.medium))
            Spacer()
            #if DEBUG
            Text("속도 \(vm.speechRate, specifier: "%.2f") · 대기 \(vm.pendingSpeechCount)")
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            DebugMenu(vm: vm)
            #endif
            Toggle("음성 끄기", isOn: Binding(get: { !vm.voiceEnabled }, set: { vm.voiceEnabled = !$0 }))
                .fixedSize()
        }
        .padding(.horizontal, 16).padding(.vertical, landscape ? 4 : 8)
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
                        Text(p).font(.title3).foregroundStyle(.secondary).opacity(0.8)
                            .padding(12).background(Color.surface, in: .rect(cornerRadius: 16))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .onChange(of: vm.messages.count) { withAnimation { proxy.scrollTo("bottom") } }
            .onChange(of: vm.partnerPartial) { proxy.scrollTo("bottom") }
        }
    }

    private func bubble(_ m: Message) -> some View {
        let mine = m.speaker == .me
        return VStack(alignment: .leading, spacing: 4) {
            Text(m.original).font(.footnote).foregroundStyle(.secondary)
            Text(m.translation).font(.title2.weight(.semibold)).foregroundStyle(.primary)
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .background(Color.surface, in: .rect(cornerRadius: 16))
        .overlay(alignment: .leading) {
            if mine { Rectangle().fill(Color.seal).frame(width: 3).padding(.vertical, 12) }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    private var talkArea: some View {
        VStack(spacing: 8) {
            if vm.retryHint { Text("다시 말해 주세요").font(.subheadline.weight(.medium)).foregroundStyle(Color.sealText) }
            if vm.isHoldingToTalk {
                Text("● 듣는 중…").font(.subheadline.weight(.medium)).foregroundStyle(Color.sealText)
                Text(vm.myPartial).font(.title3).foregroundStyle(.secondary).frame(minHeight: 28)
                    .lineLimit(landscape ? 3 : nil)
                    .minimumScaleFactor(landscape ? 0.7 : 1)
            }
            Group {
                if landscape {
                    VStack(spacing: 8) {
                        Text("🎤").font(.largeTitle)
                        Text(vm.isHoldingToTalk ? "손을 떼면\n번역해요" : "누르고\n말하기")
                            .multilineTextAlignment(.center)
                    }
                } else {
                    Text(vm.isHoldingToTalk ? "손을 떼면 번역해요" : "🎤 누르고 말하기")
                }
            }
                .font(landscape ? .headline.weight(.semibold) : .title2.weight(.semibold))
                .foregroundStyle(vm.isHoldingToTalk ? Color.white : Color.inkOn)
                .frame(maxWidth: .infinity, minHeight: 88, maxHeight: landscape ? .infinity : 88)
                .background(vm.isHoldingToTalk ? Color.seal : Color.ink, in: .rect(cornerRadius: 20))
                .onLongPressGesture(minimumDuration: .infinity, maximumDistance: 200, perform: {},
                                    onPressingChanged: { $0 ? vm.pressBegan() : vm.pressEnded() })
                .accessibilityLabel("누르고 말하기")
        }
        .padding(16)
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
