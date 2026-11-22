import Testing
@testable import Fellowship

@MainActor
private final class FakeSpeech: SpeechOutput {
    var spoken: [(text: String, rate: Float)] = []
    var stopCount = 0
    private var finishes: [@MainActor () -> Void] = []
    func speak(_ text: String, rate: Float, onFinish: @escaping @MainActor () -> Void) {
        spoken.append((text, rate)); finishes.append(onFinish)
    }
    func stopImmediately() { stopCount += 1; finishes.removeAll() }
    func finishCurrent() { if !finishes.isEmpty { finishes.removeFirst()() } }
}

@MainActor
private final class FakeListening: ListeningEngine {
    var endMineCalls: [Bool] = []
    var modes: [ListenMode] = []
    func events() -> AsyncStream<ListenEvent> { AsyncStream { _ in } }
    func setMode(_ mode: ListenMode) { modes.append(mode) }
    func endMine(valid: Bool) { endMineCalls.append(valid) }
}

@MainActor
private final class FakeChecker: ReadinessChecker {
    func readyKinds() -> Set<ReadinessKind> { Set(ReadinessKind.allCases) }
    func prepare(_ kind: ReadinessKind) async {}
    func refresh() async {}
}

@MainActor
private func makeVM(_ speech: FakeSpeech = FakeSpeech(), _ listening: FakeListening = FakeListening()) -> ConversationViewModel {
    ConversationViewModel(listening: listening, checker: FakeChecker(), speech: speech)
}

@MainActor
struct ConversationLogicTests {
    // MARK: speech queue & rate
    @Test func rateGrowsWithBacklogAndIsCapped() {
        let r = ConversationViewModel.rate(forQueueLength:)
        #expect(r(0) == 0.5)
        #expect(r(1) == 0.5)
        #expect(r(2) > r(1))
        #expect(r(3) > r(2))
        #expect(r(100) == r(50))
        #expect(r(100) <= 0.62)
    }

    @Test func queuedSentencesAreSpokenInOrderWithRisingRate() {
        let speech = FakeSpeech()
        let vm = makeVM(speech)
        for ko in ["하나", "둘", "셋", "넷"] { vm.handle(.partnerFinal(zh: "x", ko: ko)) }
        #expect(speech.spoken.map(\.text) == ["하나"]) // one at a time
        #expect(speech.spoken[0].rate == 0.5)          // queue was just 1 when it started
        speech.finishCurrent()
        speech.finishCurrent()
        speech.finishCurrent()
        #expect(speech.spoken.map(\.text) == ["하나", "둘", "셋", "넷"])
        #expect(speech.spoken[1].rate > speech.spoken[0].rate) // backlog of 3 when "둘" began
        #expect(speech.spoken[1].rate >= speech.spoken[2].rate) // backlog shrinks, rate falls back
        speech.finishCurrent()
        #expect(vm.speakQueue.isEmpty)
    }

    // MARK: short press
    @Test func pressDurationThreshold() {
        #expect(ConversationViewModel.isValidPress(duration: 0.49) == false)
        #expect(ConversationViewModel.isValidPress(duration: 0.5) == true)
    }

    @Test func shortPressIsDiscarded() {
        let listening = FakeListening()
        let vm = makeVM(FakeSpeech(), listening)
        vm.pressBegan()
        vm.pressEnded()
        #expect(listening.endMineCalls == [false])
        #expect(vm.messages.isEmpty)
        #expect(vm.showCard == nil)
    }

    // MARK: unplug
    @Test func unplugSilencesAndReplugResumes() {
        let speech = FakeSpeech()
        let vm = makeVM(speech)
        vm.handle(.partnerFinal(zh: "x", ko: "하나"))
        vm.handle(.partnerFinal(zh: "x", ko: "둘"))
        #expect(speech.spoken.count == 1)

        vm.earphonesDidChange(connected: false)
        #expect(speech.stopCount == 1)
        #expect(vm.speakQueue.isEmpty)
        #expect(vm.showUnpluggedBanner)

        vm.handle(.partnerFinal(zh: "x", ko: "셋"))
        #expect(speech.spoken.count == 1) // not spoken while unplugged
        #expect(vm.speakQueue.isEmpty)

        vm.earphonesDidChange(connected: true)
        #expect(!vm.showUnpluggedBanner)
        vm.handle(.partnerFinal(zh: "x", ko: "넷"))
        #expect(speech.spoken.map(\.text) == ["하나", "넷"])
    }

    #if DEBUG
    @Test func speakerTestModeSpeaksWithoutEarphones() {
        let speech = FakeSpeech()
        let vm = makeVM(speech)
        vm.earphonesConnected = false
        vm.handle(.partnerFinal(zh: "x", ko: "하나"))
        #expect(speech.spoken.isEmpty)
        vm.speakerTestMode = true
        vm.handle(.partnerFinal(zh: "x", ko: "둘"))
        #expect(speech.spoken.map(\.text) == ["둘"])
        vm.speakerTestMode = false
    }
    #endif
}
